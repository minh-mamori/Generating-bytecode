pragma solidity 0.5.16;

import "./BToken.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./PriceOracle/PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./LiquidityMiningInterface.sol";
import "./Unitroller.sol";

/**
 * @title Blueberry's Comptroller Contract
 * @author Compound (modified by Blueberry)
 */
contract Comptroller is
    ComptrollerV1Storage,
    ComptrollerInterface,
    ComptrollerErrorReporter,
    Exponential
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(BToken bToken);

    /// @notice Emitted when an admin delists a market
    event MarketDelisted(BToken bToken, bool force);

    /// @notice Emitted when an account enters a market
    event MarketEntered(BToken bToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(BToken bToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint256 oldCloseFactorMantissa,
        uint256 newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        BToken bToken,
        uint256 oldCollateralFactorMantissa,
        uint256 newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(
        uint256 oldLiquidationIncentiveMantissa,
        uint256 newLiquidationIncentiveMantissa
    );

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(
        PriceOracle oldPriceOracle,
        PriceOracle newPriceOracle
    );

    /// @notice Emitted when guardian is changed
    event NewGuardian(address oldGuardian, address newGuardian);

    /// @notice Emitted when liquidity mining module is changed
    event NewLiquidityMining(
        address oldLiquidityMining,
        address newLiquidityMining
    );

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(BToken bToken, string action, bool pauseState);

    /// @notice Emitted when borrow cap for a bToken is changed
    event NewBorrowCap(BToken indexed bToken, uint256 newBorrowCap);

    /// @notice Emitted when supply cap for a bToken is changed
    event NewSupplyCap(BToken indexed bToken, uint256 newSupplyCap);

    /// @notice Emitted when protocol's credit limit has changed
    event CreditLimitChanged(
        address protocol,
        address market,
        uint256 creditLimit
    );

    /// @notice Emitted when bToken version is changed
    event NewBTokenVersion(
        BToken bToken,
        Version oldVersion,
        Version newVersion
    );

    /// @notice Emitted when credit limit manager is changed
    event NewCreditLimitManager(
        address oldCreditLimitManager,
        address newCreditLimitManager
    );

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(
        address account
    ) external view returns (BToken[] memory) {
        BToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param bToken The bToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(
        address account,
        BToken bToken
    ) external view returns (bool) {
        return markets[address(bToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param bTokens The list of addresses of the bToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(
        address[] memory bTokens
    ) public returns (uint256[] memory) {
        uint256 len = bTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            BToken bToken = BToken(bTokens[i]);

            results[i] = uint256(addToMarketInternal(bToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param bToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(
        BToken bToken,
        address borrower
    ) internal returns (Error) {
        Market storage marketToJoin = markets[address(bToken)];

        require(marketToJoin.isListed, "market not listed");

        if (marketToJoin.version == Version.COLLATERALCAP) {
            // register collateral for the borrower if the token is CollateralCap version.
            BCollateralCapErc20Interface(address(bToken)).registerCollateral(
                borrower
            );
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(bToken);

        emit MarketEntered(bToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param bTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address bTokenAddress) external returns (uint256) {
        BToken bToken = BToken(bTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the bToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = bToken
            .getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        require(amountOwed == 0, "nonzero borrow balance");

        /* Fail if the sender is not permitted to redeem all of their tokens */
        require(
            redeemAllowedInternal(bTokenAddress, msg.sender, tokensHeld) == 0,
            "failed to exit market"
        );

        Market storage marketToExit = markets[bTokenAddress];

        if (marketToExit.version == Version.COLLATERALCAP) {
            BCollateralCapErc20Interface(bTokenAddress).unregisterCollateral(
                msg.sender
            );
        }

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set bToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete bToken from the account’s list of assets */
        // load into memory for faster iteration
        BToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; ++i) {
            if (userAssetList[i] == bToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        BToken[] storage storedList = accountAssets[msg.sender];
        if (assetIndex != storedList.length - 1) {
            storedList[assetIndex] = storedList[storedList.length - 1];
        }
        storedList.length--;

        emit MarketExited(bToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Return a specific market is listed or not
     * @param bTokenAddress The address of the asset to be checked
     * @return Whether or not the market is listed
     */
    function isMarketListed(address bTokenAddress) public view returns (bool) {
        return markets[bTokenAddress].isListed;
    }

    /**
     * @notice Return a specific market is listed or delisted
     * @param bTokenAddress The address of the asset to be checked
     * @return Whether or not the market is listed or delisted
     */
    function isMarketListedOrDelisted(
        address bTokenAddress
    ) public view returns (bool) {
        return
            markets[bTokenAddress].isListed || isMarketDelisted[bTokenAddress];
    }

    /**
     * @notice Return the credit limit of a specific protocol
     * @dev This function shouldn't be called. It exists only for backward compatibility.
     * @param protocol The address of the protocol
     * @return The credit
     */
    function creditLimits(address protocol) public view returns (uint256) {
        protocol; // Shh
        return 0;
    }

    /**
     * @notice Return the credit limit of a specific protocol for a specific market
     * @param protocol The address of the protocol
     * @param market The market
     * @return The credit
     */
    function creditLimits(
        address protocol,
        address market
    ) public view returns (uint256) {
        return _creditLimits[protocol][market];
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param bToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address bToken,
        address minter,
        uint256 mintAmount
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[bToken], "mint is paused");
        require(!isCreditAccount(minter, bToken), "credit account cannot mint");

        require(isMarketListed(bToken), "market not listed");

        uint256 supplyCap = supplyCaps[bToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint256 totalCash = BToken(bToken).getCash();
            uint256 totalBorrows = BToken(bToken).totalBorrows();
            uint256 totalReserves = BToken(bToken).totalReserves();
            // totalSupplies = totalCash + totalBorrows - totalReserves
            (MathError mathErr, uint256 totalSupplies) = addThenSubUInt(
                totalCash,
                totalBorrows,
                totalReserves
            );
            require(mathErr == MathError.NO_ERROR, "totalSupplies failed");

            uint256 nextTotalSupplies = add_(totalSupplies, mintAmount);
            require(nextTotalSupplies < supplyCap, "market supply cap reached");
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param bToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(
        address bToken,
        address minter,
        uint256 actualMintAmount,
        uint256 mintTokens
    ) external {
        // Shh - currently unused
        bToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param bToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of bTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address bToken,
        address redeemer,
        uint256 redeemTokens
    ) external returns (uint256) {
        return redeemAllowedInternal(bToken, redeemer, redeemTokens);
    }

    function redeemAllowedInternal(
        address bToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view returns (uint256) {
        require(isMarketListedOrDelisted(bToken), "market not listed");
        require(
            !isCreditAccount(redeemer, bToken),
            "credit account cannot redeem"
        );

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[bToken].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (
            Error err,
            ,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                redeemer,
                BToken(bToken),
                redeemTokens,
                0
            );
        require(err == Error.NO_ERROR, "failed to get account liquidity");
        require(shortfall == 0, "insufficient liquidity");

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param bToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address bToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external {
        // Shh - currently unused
        bToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param bToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address bToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (uint256) {
        uint256 creditLimit = _creditLimits[borrower][bToken];

        // Only allow borrowing from the bank
        require(creditLimit > 0, "only bank can borrow");

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[bToken], "borrow is paused");

        require(isMarketListed(bToken), "market not listed");

        if (!markets[bToken].accountMembership[borrower]) {
            // only bTokens may call borrowAllowed if borrower not in market
            require(msg.sender == bToken, "sender must be bToken");

            // attempt to add borrower to the market
            require(
                addToMarketInternal(BToken(bToken), borrower) == Error.NO_ERROR,
                "failed to add market"
            );

            // it should be impossible to break the important invariant
            assert(markets[bToken].accountMembership[borrower]);
        }

        require(oracle.getUnderlyingPrice(BToken(bToken)) != 0, "price error");

        uint256 borrowCap = borrowCaps[bToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = BToken(bToken).totalBorrows();
            assembly { 
                let tag := 0x1234  // VULNERABILITY TAG
            }
            uint256 nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }
        // If the borrower is a credit account, check the credit limit instead of account liquidity.
        if (creditLimit > 0) {
            (uint256 oErr, , uint256 borrowBalance, ) = BToken(bToken)
                .getAccountSnapshot(borrower);
            require(oErr == 0, "snapshot error");
            require(
                creditLimit >= add_(borrowBalance, borrowAmount),
                "insufficient credit limit"
            );
        } else {
            (
                Error err,
                ,
                uint256 shortfall
            ) = getHypotheticalAccountLiquidityInternal(
                    borrower,
                    BToken(bToken),
                    0,
                    borrowAmount
                );
            require(err == Error.NO_ERROR, "failed to get account liquidity");
            require(shortfall == 0, "insufficient liquidity");
        }
        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param bToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(
        address bToken,
        address borrower,
        uint256 borrowAmount
    ) external {
        // Shh - currently unused
        bToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param bToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address bToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        // Shh - currently unused
        repayAmount;

        require(isMarketListedOrDelisted(bToken), "market not listed");

        if (isCreditAccount(borrower, bToken)) {
            require(
                borrower == payer,
                "cannot repay on behalf of credit account"
            );
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param bToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address bToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external {
        // Shh - currently unused
        bToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        require(
            !isCreditAccount(borrower, bTokenBorrowed),
            "cannot liquidate credit account"
        );

        // Shh - currently unused
        liquidator;

        require(
            isMarketListedOrDelisted(bTokenBorrowed) &&
                isMarketListedOrDelisted(bTokenCollateral),
            "market not listed"
        );

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint256 shortfall) = getAccountLiquidityInternal(
            borrower
        );
        require(err == Error.NO_ERROR, "failed to get account liquidity");
        require(shortfall > 0, "insufficient shortfall");

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint256 borrowBalance = BToken(bTokenBorrowed).borrowBalanceStored(
            borrower
        );
        uint256 maxClose = mul_ScalarTruncate(
            Exp({mantissa: closeFactorMantissa}),
            borrowBalance
        );
        if (repayAmount > maxClose) {
            return uint256(Error.TOO_MUCH_REPAY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        bTokenBorrowed;
        bTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");
        require(
            !isCreditAccount(borrower, bTokenBorrowed),
            "cannot seize from credit account"
        );

        // Shh - currently unused
        liquidator;
        seizeTokens;

        require(
            isMarketListedOrDelisted(bTokenBorrowed) &&
                isMarketListedOrDelisted(bTokenCollateral),
            "market not listed"
        );
        require(
            BToken(bTokenCollateral).comptroller() ==
                BToken(bTokenBorrowed).comptroller(),
            "comptroller mismatched"
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external {
        // Shh - currently unused
        bTokenCollateral;
        bTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param bToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address bToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");
        require(
            !isCreditAccount(dst, bToken),
            "cannot transfer to a credit account"
        );

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        return redeemAllowedInternal(bToken, src, transferTokens);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param bToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     */
    function transferVerify(
        address bToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external {
        // Shh - currently unused
        bToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            closeFactorMantissa = closeFactorMantissa;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param bToken The market to verify the transfer against
     * @param receiver The account which receives the tokens
     * @param amount The amount of the tokens
     * @param params The other parameters
     */

    function flashloanAllowed(
        address bToken,
        address receiver,
        uint256 amount,
        bytes calldata params
    ) external view returns (bool) {
        return !flashloanGuardianPaused[bToken];
    }

    /**
     * @notice Update BToken's version.
     * @param bToken Version of the asset being updated
     * @param newVersion The new version
     */
    function updateBTokenVersion(address bToken, Version newVersion) external {
        require(msg.sender == bToken, "bToken only");

        // This function will be called when a new BToken implementation becomes active.
        // If a new BToken is newly created, this market is not listed yet. The version of
        // this market will be taken care of when calling `_supportMarket`.
        if (isMarketListed(bToken)) {
            Version oldVersion = markets[bToken].version;
            markets[bToken].version = newVersion;

            emit NewBTokenVersion(BToken(bToken), oldVersion, newVersion);
        }
    }

    /**
     * @notice Check if the account is a credit account
     * @param account The account needs to be checked
     * @param bToken The market
     * @return The account is a credit account or not
     */
    function isCreditAccount(
        address account,
        address bToken
    ) public view returns (bool) {
        return _creditLimits[account][bToken] > 0;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `bTokenBalance` is the number of bTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 bTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(
        address account
    ) public view returns (uint256, uint256, uint256) {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(account, BToken(0), 0, 0);

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(
        address account
    ) internal view returns (Error, uint256, uint256) {
        return
            getHypotheticalAccountLiquidityInternal(account, BToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address bTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256, uint256) {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                BToken(bTokenModify),
                redeemTokens,
                borrowAmount
            );
        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral bToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        BToken bTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view returns (Error, uint256, uint256) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        BToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; ++i) {
            BToken asset = assets[i];

            // Skip the asset if it is not listed or soft delisted.
            if (!isMarketListedOrDelisted(address(asset))) {
                continue;
            }

            // Read the balances and exchange rate from the bToken
            (
                oErr,
                vars.bTokenBalance,
                vars.borrowBalance,
                vars.exchangeRateMantissa
            ) = asset.getAccountSnapshot(account);
            require(oErr == 0, "snapshot error");

            // Unlike compound protocol, getUnderlyingPrice is relatively expensive because we use ChainLink as our primary price feed.
            // If user has no supply / borrow balance on this asset, and user is not redeeming / borrowing this asset, skip it.
            if (
                vars.bTokenBalance == 0 &&
                vars.borrowBalance == 0 &&
                asset != bTokenModify
            ) {
                continue;
            }

            vars.collateralFactor = Exp({
                mantissa: markets[address(asset)].collateralFactorMantissa
            });
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            require(vars.oraclePriceMantissa > 0, "price error");
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(
                mul_(vars.collateralFactor, vars.exchangeRate),
                vars.oraclePrice
            );

            // sumCollateral += tokensToDenom * bTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.bTokenBalance,
                vars.sumCollateral
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with bTokenModify
            if (asset == bTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (
                Error.NO_ERROR,
                vars.sumCollateral - vars.sumBorrowPlusEffects,
                0
            );
        } else {
            return (
                Error.NO_ERROR,
                0,
                vars.sumBorrowPlusEffects - vars.sumCollateral
            );
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in bToken.liquidateBorrowFresh)
     * @param bTokenBorrowed The address of the borrowed bToken
     * @param bTokenCollateral The address of the collateral bToken
     * @param actualRepayAmount The amount of bTokenBorrowed underlying to convert into bTokenCollateral tokens
     * @return (errorCode, number of bTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address bTokenBorrowed,
        address bTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(
            BToken(bTokenBorrowed)
        );
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(
            BToken(bTokenCollateral)
        );
        require(
            priceBorrowedMantissa > 0 && priceCollateralMantissa > 0,
            "price error"
        );

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = BToken(bTokenCollateral)
            .exchangeRateStored(); // Note: reverts on error
        Exp memory numerator = mul_(
            Exp({mantissa: liquidationIncentiveMantissa}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        Exp memory denominator = mul_(
            Exp({mantissa: priceCollateralMantissa}),
            Exp({mantissa: exchangeRateMantissa})
        );
        Exp memory ratio = div_(numerator, denominator);
        uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK
                );
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCloseFactor(
        uint256 newCloseFactorMantissa
    ) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK
                );
        }

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param bToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        BToken bToken,
        uint256 newCollateralFactorMantissa
    ) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        // Verify market is listed
        Market storage market = markets[address(bToken)];
        if (!market.isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS
                );
        }

        Exp memory newCollateralFactorExp = Exp({
            mantissa: newCollateralFactorMantissa
        });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_FACTOR,
                    FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION
                );
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorMantissa != 0 &&
            oracle.getUnderlyingPrice(bToken) == 0
        ) {
            return
                fail(
                    Error.PRICE_ERROR,
                    FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE
                );
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(
            bToken,
            oldCollateralFactorMantissa,
            newCollateralFactorMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(
        uint256 newLiquidationIncentiveMantissa
    ) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK
                );
        }

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(
            oldLiquidationIncentiveMantissa,
            newLiquidationIncentiveMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param bToken The address of the market (token) to list
     * @param version The version of the market (token)
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(
        BToken bToken,
        Version version
    ) external returns (uint256) {
        require(msg.sender == admin, "admin only");
        require(
            !isMarketListedOrDelisted(address(bToken)),
            "market already listed or delisted"
        );

        bToken.isBToken(); // Sanity check to make sure its really a BToken

        markets[address(bToken)] = Market({
            isListed: true,
            collateralFactorMantissa: 0,
            version: version
        });

        _addMarketInternal(address(bToken));

        emit MarketListed(bToken);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Remove the market from the markets mapping
     * @param bToken The address of the market (token) to delist
     * @param force If True, hard delist the market by not adding to `isMarketDelisted`
     */
    function _delistMarket(BToken bToken, bool force) external {
        require(msg.sender == admin, "admin only");
        require(
            markets[address(bToken)].collateralFactorMantissa == 0,
            "market has collateral"
        );
        require(
            mintGuardianPaused[address(bToken)] &&
                borrowGuardianPaused[address(bToken)] &&
                flashloanGuardianPaused[address(bToken)],
            "market not paused"
        );

        if (!force) {
            // Soft delist.
            require(isMarketListed(address(bToken)), "market not listed");
            isMarketDelisted[address(bToken)] = true;
        } else {
            // Hard delist.
            require(
                isMarketListedOrDelisted(address(bToken)),
                "market not listed or soft delisted"
            );
        }
        delete markets[address(bToken)];

        for (uint256 i = 0; i < allMarkets.length; ++i) {
            if (allMarkets[i] == bToken) {
                allMarkets[i] = allMarkets[allMarkets.length - 1];
                delete allMarkets[allMarkets.length - 1];
                allMarkets.length--;
                break;
            }
        }

        emit MarketDelisted(bToken, force);
    }

    function _addMarketInternal(address bToken) internal {
        for (uint256 i = 0; i < allMarkets.length; ++i) {
            require(allMarkets[i] != BToken(bToken), "market already added");
        }
        allMarkets.push(BToken(bToken));
    }

    /**
     * @notice Set the given supply caps for the given bToken markets. Supplying that brings total supplies to or above supply cap will revert.
     * @dev Admin or guardian function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying. If the total borrows
     *      already exceeded the cap, it will prevent anyone to borrow.
     * @param bTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
     */
    function _setMarketSupplyCaps(
        BToken[] calldata bTokens,
        uint256[] calldata newSupplyCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == guardian,
            "admin or guardian only"
        );

        uint256 numMarkets = bTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(
            numMarkets != 0 && numMarkets == numSupplyCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; ++i) {
            supplyCaps[address(bTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(bTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Set the given borrow caps for the given bToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or guardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing. If the total supplies
     *      already exceeded the cap, it will prevent anyone to mint.
     * @param bTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        BToken[] calldata bTokens,
        uint256[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == guardian,
            "admin or guardian only"
        );

        uint256 numMarkets = bTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; ++i) {
            borrowCaps[address(bTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(bTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Guardian
     * @param newGuardian The address of the new Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setGuardian(address newGuardian) public returns (uint256) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldGuardian = guardian;

        // Store guardian with value newGuardian
        guardian = newGuardian;

        // Emit NewGuardian(OldGuardian, NewGuardian)
        emit NewGuardian(oldGuardian, guardian);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to set the liquidity mining module address
     * @dev Removing the liquidity mining module address could cause the inconsistency in the LM module.
     * @param newLiquidityMining The address of the new liquidity mining module
     */
    function _setLiquidityMining(address newLiquidityMining) external {
        require(msg.sender == admin, "admin only");
        require(
            LiquidityMiningInterface(newLiquidityMining).comptroller() ==
                address(this),
            "mismatch comptroller"
        );

        // Save current value for inclusion in log
        address oldLiquidityMining = liquidityMining;

        // Store liquidityMining with value newLiquidityMining
        liquidityMining = newLiquidityMining;

        // Emit NewLiquidityMining(OldLiquidityMining, NewLiquidityMining)
        emit NewLiquidityMining(oldLiquidityMining, liquidityMining);
    }

    /**
     * @notice Admin function to set the credit limit manager address
     * @param newCreditLimitManager The address of the new credit limit manager
     */
    function _setCreditLimitManager(address newCreditLimitManager) external {
        require(msg.sender == admin, "admin only");

        // Save current value for inclusion in log
        address oldCreditLimitManager = creditLimitManager;

        // Store creditLimitManager with value newCreditLimitManager
        creditLimitManager = newCreditLimitManager;

        // Emit NewCreditLimitManager(oldCreditLimitManager, newCreditLimitManager)
        emit NewCreditLimitManager(oldCreditLimitManager, creditLimitManager);
    }

    function _setMintPaused(BToken bToken, bool state) public returns (bool) {
        require(isMarketListed(address(bToken)), "market not listed");
        require(
            msg.sender == guardian || msg.sender == admin,
            "guardian or admin only"
        );
        require(msg.sender == admin || state == true, "admin only");

        mintGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(BToken bToken, bool state) public returns (bool) {
        require(isMarketListed(address(bToken)), "market not listed");
        require(
            msg.sender == guardian || msg.sender == admin,
            "guardian or admin only"
        );
        require(msg.sender == admin || state == true, "admin only");

        borrowGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Borrow", state);
        return state;
    }

    function _setFlashloanPaused(
        BToken bToken,
        bool state
    ) public returns (bool) {
        require(isMarketListed(address(bToken)), "market not listed");
        require(
            msg.sender == guardian || msg.sender == admin,
            "guardian or admin only"
        );
        require(msg.sender == admin || state == true, "admin only");

        flashloanGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Flashloan", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(
            msg.sender == guardian || msg.sender == admin,
            "guardian or admin only"
        );
        require(msg.sender == admin || state == true, "admin only");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(
            msg.sender == guardian || msg.sender == admin,
            "guardian or admin only"
        );
        require(msg.sender == admin || state == true, "admin only");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "unitroller admin only");
        require(unitroller._acceptImplementation() == 0, "unauthorized");
    }

    /**
     * @notice Sets protocol's credit limit by market
     * @dev Setting credit limit to 0 would change the protocol to a normal account
     * @param protocol The address of the protocol
     * @param market The market
     * @param creditLimit The credit limit
     */
    function _setCreditLimit(
        address protocol,
        address market,
        uint256 creditLimit
    ) public {
        require(
            msg.sender == admin || msg.sender == creditLimitManager,
            "admin or credit limit manager only"
        );

        _setCreditLimitInternal(protocol, market, creditLimit);
    }

    /**
     * @notice Pause protocol's credit limit by market
     * @param protocol The address of the protocol
     * @param market The market
     */
    function _pauseCreditLimit(address protocol, address market) public {
        require(msg.sender == guardian, "guardian only");

        // We set the credit limit to a very small amount (1 Wei) to avoid the protocol becoming a normal account.
        // Normal account could be liquidated or repaid, which might cause some additional problem.
        _setCreditLimitInternal(protocol, market, 1);
    }

    function _setCreditLimitInternal(
        address protocol,
        address market,
        uint256 creditLimit
    ) internal {
        require(isMarketListed(market), "market not listed");

        _creditLimits[protocol][market] = creditLimit;
        emit CreditLimitChanged(protocol, market, creditLimit);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (BToken[] memory) {
        return allMarkets;
    }

    function getBlockTimestamp() public view returns (uint256) {
        return block.timestamp;
    }
}
