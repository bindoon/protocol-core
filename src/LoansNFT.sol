// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { CollarTakerNFT, ICollarTakerNFT, ITakerOracle, BaseNFT, ConfigHub } from "./CollarTakerNFT.sol";
import { Rolls, CollarProviderNFT, IRolls } from "./Rolls.sol";
import { EscrowSupplierNFT, IEscrowSupplierNFT } from "./EscrowSupplierNFT.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { ILoansNFT } from "./interfaces/ILoansNFT.sol";

/**
 * @title LoansNFT
 * @custom:security-contact security@collarprotocol.xyz
 * @dev This contract manages opening, closing, and rolling of loans via Collar positions,
 * with optional escrow support.
 *
 * Main Functionality:
 * 1. Allows users to open loans by providing underlying and borrowing against it, with or without escrow.
 * 2. Handles the swapping of underlying to the cash asset via allowed Swappers (that use dex routers).
 * 3. Wraps CollarTakerNFT (keeps it in the contract), and mints an NFT with loanId == takerId to the user.
 * 4. Manages loan closure, repayment of cash, swapping back to underlying, and releasing escrow if needed.
 * 5. Provides keeper functionality for automated loan closure to mitigate price fluctuation risks.
 * 6. Allows rolling (extending) the loan via an owner and user approved Rolls contract.
 *
 * Key Assumptions and Prerequisites:
 * 1. Allowed Swappers and the dex routers / aggregators they use are properly implemented.
 * 2. Depends on ConfigHub, CollarTakerNFT, CollarProviderNFT, EscrowSupplierNFT, Rolls, and their
 * dependencies (Oracle).
 * 3. Assets (ERC-20) used are simple: no hooks, balance updates only and exactly
 * according to transfer arguments (no rebasing, no FoT), 0 value approvals and transfers work.
 *
 * Post-Deployment Configuration:
 * - ConfigHub: Set setCanOpenPair() to authorize this contract for its asset pair [underlying, cash, loans]
 * - ConfigHub: Set setCanOpenPair() to authorize: taker, provider, rolls for pair [underlying, cash, ...]
 * - ConfigHub: If allowing escrow, set setCanOpenPair() to authorize escrow [underlying, ANY_ASSET, escrow].
 * - ConfigHub: If allowing escrow, set setCanOpenPair() to authorize loans for escrow [underlying, escrow, loans].
 * - CollarTakerNFT and CollarProviderNFT: Ensure properly configured
 * - EscrowSupplierNFT: If allowing escrow, ensure properly configured
 * - This Contract: Set an allowed default swapper
 */
contract LoansNFT is ILoansNFT, BaseNFT {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint internal constant BIPS_BASE = 10_000;

    string public constant VERSION = "0.3.0";
    uint public constant MAX_SWAP_PRICE_DEVIATION_BIPS = 1000; // 10%, allows 10% self-sandwich slippage

    // ----- IMMUTABLES ----- //
    CollarTakerNFT public immutable takerNFT;
    IERC20 public immutable cashAsset;
    IERC20 public immutable underlying;

    // ----- STATE VARIABLES ----- //

    // ----- User state ----- //
    /// @notice Stores loan information for each NFT ID
    mapping(uint loanId => LoanStored) internal loans;
    // borrowers that allow a keeper for loan closing for specific loans
    mapping(address sender => mapping(uint loanId => address keeper)) public keeperApprovedFor;

    // ----- Admin state ----- //
    // contracts allowed for swaps
    EnumerableSet.AddressSet internal allowedSwappers;
    // a convenience view to allow querying for a swapper onchain / FE without subgraph
    address public defaultSwapper;

    constructor(CollarTakerNFT _takerNFT, string memory _name, string memory _symbol)
        BaseNFT(_name, _symbol, _takerNFT.configHub())
    {
        takerNFT = _takerNFT;
        cashAsset = _takerNFT.cashAsset();
        underlying = _takerNFT.underlying();
    }

    modifier onlyNFTOwner(uint loanId) {
        /// @dev will also revert on non-existent (unminted / burned) loan ID
        require(msg.sender == ownerOf(loanId), "loans: not NFT owner");
        _;
    }

    // ----- VIEW FUNCTIONS ----- //

    /// @notice Retrieves loan information for a given taker NFT ID
    function getLoan(uint loanId) public view returns (Loan memory) {
        LoanStored memory stored = loans[loanId];
        return Loan({
            underlyingAmount: stored.underlyingAmount,
            loanAmount: stored.loanAmount,
            usesEscrow: stored.usesEscrow,
            escrowNFT: stored.escrowNFT,
            escrowId: stored.escrowId
        });
    }

    /// @notice Checks whether a swapper is allowed for this contract
    function isAllowedSwapper(address swapper) public view returns (bool) {
        return allowedSwappers.contains(swapper);
    }

    /// @notice Returns all the swappers allowed for this loans contract
    function allAllowedSwappers() external view returns (address[] memory) {
        return allowedSwappers.values();
    }

    // ----- STATE CHANGING FUNCTIONS ----- //

    // ----- User / Keeper methods ----- //

    /**
    * @notice Opens a new loan by providing underlying and borrowing against it (without using escrow)
     *      1. Transfers underlying from the user to this contract
     *      2. Swaps underlying for cash
     *      3. Opens a loan position using the CollarTakerNFT contract
     *      4. Transfers the borrowed amount to the user
     *      5. Transfers the minted NFT to the user
     * @param underlyingAmount The amount of underlying asset to be provided
     * @param minLoanAmount The minimum acceptable loan amount (slippage protection)
     * @param swapParams SwapParams struct with:
     *     - The minimum acceptable amount of cash from the underlying swap (slippage protection)
     *     - an allowed Swapper
     *     - any extraData the swapper needs to use
     * @param providerOffer The address of provider NFT and ID of the liquidity offer to use
     * @return loanId The ID of the minted NFT representing the loan
     * @return providerId The ID of the minted CollarProviderNFT paired with this loan
     * @return loanAmount The actual amount of the loan opened in cash asset
     
     * @notice 开启新的标准借贷（不使用托管）
     *      1. 从用户转移underlying资产到合约
     *      2. 将underlying交换为cash
     *      3. 使用CollarTakerNFT合约开启借贷头寸
     *      4. 将借到的金额转移给用户
     *      5. 将铸造的NFT转移给用户
     * @param underlyingAmount 提供的underlying资产数量
     * @param minLoanAmount 可接受的最小借贷金额（滑点保护）
     * @param swapParams 交换参数结构体，包含：
     *     - 从underlying交换得到的最小cash数量（滑点保护）
     *     - 允许使用的交换器地址
     *     - 交换器需要的额外数据
     * @param providerOffer 要使用的provider NFT地址和流动性报价ID
     * @return loanId 代表借贷的NFT的ID
     * @return providerId 配对的CollarProviderNFT的ID
     * @return loanAmount 以cash资产计的实际借贷金额
     */
    function openLoan(
        uint underlyingAmount,        // 用户要抵押的underlying资产数量
        uint minLoanAmount,           // 用户可接受的最小借贷金额
        SwapParams calldata swapParams,   // 交换参数，包含滑点保护等
        ProviderOffer calldata providerOffer  // 选择的流动性提供者报价
    ) external returns (uint loanId, uint providerId, uint loanAmount) {
        // 创建一个空的托管报价结构体，表示不使用托管
        EscrowOffer memory noEscrow = EscrowOffer(EscrowSupplierNFT(address(0)), 0);
        
        // 调用内部函数_openLoan，传入false表示不使用托管
        return _openLoan(underlyingAmount, minLoanAmount, swapParams, providerOffer, false, noEscrow, 0);
    }

    /**
     * @notice Opens a new escrow-type loan by providing underlying and borrowing against it
     *      1. Transfers underlying from the user to this contract
     *      2. Uses the escrow contract to deposit user's underlying, and take supplier's underlying
     *      3. Swaps underlying for cash
     *      4. Opens a loan position using the CollarTakerNFT contract
     *      5. Transfers the borrowed amount to the user
     *      6. Transfers the minted NFT to the user
     * @param underlyingAmount The amount of underlying asset to be provided
     * @param minLoanAmount The minimum acceptable loan amount (slippage protection)
     * @param swapParams SwapParams struct with:
     *     - The minimum acceptable amount of cash from the underlying swap (slippage protection)
     *     - an allowed Swapper
     *     - any extraData the swapper needs to use
     * @param providerOffer The providerNFT and ID of the liquidity offer to use
     * @param escrowOffer The escrowNFT and ID of the escrow offer to use
     * @param escrowFees The escrow interest fee and late fee to be paid / held upfront
     * @return loanId The ID of the minted NFT representing the loan
     * @return providerId The ID of the minted CollarProviderNFT paired with this loan
     * @return loanAmount The actual amount of the loan opened in cash asset
     */
    function openEscrowLoan(
        uint underlyingAmount,
        uint minLoanAmount,
        SwapParams calldata swapParams,
        ProviderOffer calldata providerOffer,
        EscrowOffer calldata escrowOffer,
        uint escrowFees
    ) external returns (uint loanId, uint providerId, uint loanAmount) {
        return _openLoan(
            underlyingAmount, minLoanAmount, swapParams, providerOffer, true, escrowOffer, escrowFees
        );
    }

    /**
     * @notice Closes an existing loan, repaying the borrowed amount and returning underlying.
     * If escrow was used, releases it by returning the swapped underlying in exchange for the
     * user's underlying, returning leftover fees if any.
     * The amount of underlying returned may be smaller or larger than originally deposited,
     * depending on the position's settlement result, escrow late fees, and the final swap.
     * In a future version, custom repayment amounts can be allowed to control the underlying
     * amount more precisely.
     * This method can be called by either the loanId's NFT owner or by a keeper,
     * if the keeper was allowed for this loan by the current owner (by calling setKeeperApproved).
     * Using a keeper may be desired because the call's timing should be as close to settlement
     * as possible, to avoid additional price exposure since the swaps uses the spot price.
     * However, allowing a keeper also trusts them to set the swap parameters, trusting them
     * with the entire swap amount (to not self-sandwich, or lose it to MEV).
     * To instead settle in cash (and avoid both repayment and swap) the user can call unwrapAndCancelLoan
     * to unwrap the CollarTakerNFT to settle it and withdraw it directly.
     * @dev the user must have approved this contract for cash asset for repayment prior to calling.
     * @dev This function:
     *      1. Transfers the repayment amount from the user to this contract
     *      2. Settles the CollarTakerNFT position if needed
     *      3. Withdraws any available funds from the settled position
     *      4. Swaps the total cash amount back to underlying asset
     *      5. Releases the escrow if needed
     *      6. Transfers the underlying back to the user
     *      7. Burns the NFT
     * @param loanId The ID of the CollarTakerNFT representing the loan to close
     * @param swapParams SwapParams struct with:
     *     - The minimum acceptable amount of underlying to receive (slippage protection)
     *     - an allowed Swapper
     *     - any extraData the swapper needs to use
     * @return underlyingOut The actual amount of underlying asset returned to the user
     */
    function closeLoan(uint loanId, SwapParams calldata swapParams) external returns (uint underlyingOut) {
        // @dev cache the borrower now, since _closeLoan will burn the NFT, so ownerOf will revert
        // Borrower is the NFT owner, since msg.sender can be a keeper.
        // If called by keeper, the borrower must trust it because:
        // - call pulls borrower funds (for repayment)
        // - call burns the NFT from borrower
        // - call sends the final funds to the borrower
        // - keeper sets the SwapParams and its slippage parameter
        /// @dev ownerOf will revert on non-existent (unminted / burned) loan ID
        address borrower = ownerOf(loanId);
        require(_isSenderOrKeeperFor(borrower, loanId), "loans: not NFT owner or allowed keeper");

        // burn token. This prevents any other (or reentrant) calls for this loan
        _burn(loanId);

        // @dev will check settle, or try to settle - will revert if cannot settle yet (not expired)
        uint takerWithdrawal = _settleAndWithdrawTaker(loanId);

        Loan memory loan = getLoan(loanId);
        // full repayment is supported, if funds aren't available for full repayment, cash only
        // settlement is available via unwrapAndCancelLoan()
        uint repayment = loan.loanAmount;

        // @dev assumes approval
        cashAsset.safeTransferFrom(borrower, address(this), repayment);

        // total cash available
        uint cashAmount = repayment + takerWithdrawal;
        // @dev Reentrancy assumption: no user state writes or reads AFTER the swapper call in _swap.
        uint underlyingFromSwap = _swap(cashAsset, underlying, cashAmount, swapParams);

        // release escrow if it was used, returning leftover fees if any.
        underlyingOut = _conditionalEndEscrow(loan, underlyingFromSwap);

        underlying.safeTransfer(borrower, underlyingOut);

        emit LoanClosed(loanId, msg.sender, borrower, repayment, cashAmount, underlyingFromSwap);
    }

    /**
     * @notice Rolls an existing loan to a new taker position with updated terms via a Rolls contract.
     * The loan amount is updated according to the funds transferred (excluding the roll-fee), and the
     * underlying is unchanged.
     * If the loan uses escrow, the previous escrow is switched for a new escrow, the new fee is pulled
     * from the user, and any refund for the previous escrow fee is sent to the user.
     * @dev The user must have approved this contract prior to calling:
     *      - Cash asset for potential repayment (if needed for Roll execution)
     *      - Underlying asset for new escrow fee (if the original loan used escrow)
     * @param loanId The ID of the NFT representing the loan to be rolled
     * @param rollOffer The Rolls contract and ID of the roll offer to be executed
     * @param minToUser The minimum acceptable transfer to user (negative if expecting to pay)
     * @param newEscrowOfferId An offer ID for the new escrow to be opened if the loan is using
     * an escrow. The previously used escrowNFT contract will be used, but an offer must be supplied.
     * Argument ignored if escrow was not used.
     * @param newEscrowFee The full interest fee for the new escrow (the old fee will be partially
     * refunded). Argument ignored if escrow was not used.
     * @return newLoanId The ID of the newly minted NFT representing the rolled loan
     * @return newLoanAmount The updated loan amount after rolling
     * @return toUser The actual transfer to user (or from user if negative) including roll-fee
     */
    function rollLoan(
        uint loanId,
        RollOffer calldata rollOffer,
        int minToUser,
        uint newEscrowOfferId,
        uint newEscrowFee
    ) external onlyNFTOwner(loanId) returns (uint newLoanId, uint newLoanAmount, int toUser) {
        // check opening loans is still allowed (not in exit-only mode)
        require(
            configHub.canOpenPair(address(underlying), address(cashAsset), address(this)),
            "loans: unsupported loans"
        );

        // @dev rolls contract is assumed to not allow rolling an expired or settled position,
        // but checking explicitly is safer and easier to review
        require(block.timestamp <= _expiration(loanId), "loans: loan expired");

        // burn token. This prevents any further calls for this loan
        _burn(loanId);

        // pull and push NFT and cash, execute roll, emit event
        (uint newTakerId, int _toUser, int rollFee) = _executeRoll(loanId, rollOffer, minToUser);
        toUser = _toUser; // convenience to allow declaring all outputs above

        Loan memory prevLoan = getLoan(loanId);
        // calculate the updated loan amount (changed due to the roll).
        // Note that although the loan amount may change (due to roll), the escrow amount should not.
        // This is because the escrow holds the borrower funds that correspond to the loan's first swap,
        // so should remain unchanged to return as much of it as possible in the end.
        newLoanAmount = _loanAmountAfterRoll(toUser, rollFee, prevLoan.loanAmount);

        // set the new ID from new taker ID
        newLoanId = _newLoanIdCheck(newTakerId);

        // switch escrows if escrow was used because collar expiration has changed
        // @dev assumes interest fee approval
        uint newEscrowId = _conditionalSwitchEscrow(prevLoan, newEscrowOfferId, newLoanId, newEscrowFee);

        // store the new loan data
        loans[newLoanId] = LoanStored({
            underlyingAmount: prevLoan.underlyingAmount,
            loanAmount: newLoanAmount,
            usesEscrow: prevLoan.usesEscrow,
            escrowNFT: prevLoan.escrowNFT,
            escrowId: SafeCast.toUint64(newEscrowId)
        });

        // mint the new loan NFT to the user, keep the taker NFT (with the same ID) in this contract
        _mint(msg.sender, newLoanId); // @dev does not use _safeMint to avoid reentrancy

        emit LoanRolled(
            msg.sender,
            loanId,
            rollOffer.id,
            newLoanId,
            prevLoan.loanAmount,
            newLoanAmount,
            toUser,
            newEscrowId
        );
    }

    /**
     * @notice Cancels an active loan, burns the loan NFT, and unwraps the taker NFT to user,
     * disconnecting it from the loan.
     * If escrow was used, releases the escrow if it wasn't released and sends any
     * escrow fee refunds to the caller.
     * @param loanId The ID representing the loan to unwrap and cancel
     */
    function unwrapAndCancelLoan(uint loanId) external onlyNFTOwner(loanId) {
        // release escrow if needed with refunds (interest fee) to sender
        _conditionalCheckAndCancelEscrow(loanId);

        // burn token. This prevents any further calls for this loan
        _burn(loanId);

        // unwrap: send the taker NFT to user
        takerNFT.transferFrom(address(this), msg.sender, _takerId(loanId));

        emit LoanCancelled(loanId, msg.sender);
    }

    /**
     * @notice Sets a keeper for closing a specific loan on behalf of a caller.
     * A user that sets this allowance with the intention for the keeper to closeLoan
     * has to also ensure cash approval to this contract that should be valid when
     * closeLoan is called by the keeper.
     * To unset, set keeper to address(0).
     * If the loan is transferred to another owner, this approval will become invalid, because the loan
     * is held by someone else. However, if it is transferred back to the original approver, the approval
     * will become valid again.
     * @param loanId specific loanId which the user approves the keeper to close
     * @param keeper address of the keeper the user approves
     */
    function setKeeperFor(uint loanId, address keeper) external {
        keeperApprovedFor[msg.sender][loanId] = keeper;
        emit ClosingKeeperApproved(msg.sender, loanId, keeper);
    }

    // ----- Admin methods ----- //

    /// @notice Enables or disables swappers and sets the defaultSwapper view.
    /// When no swapper is allowed, opening and closing loans will not be possible, only cancelling.
    /// The default swapper is a convenience view, and it's best to keep it up to date
    /// and to make sure the default one is allowed.
    /// @dev only configHub owner
    function setSwapperAllowed(address swapper, bool allow, bool setDefault) external onlyConfigHubOwner {
        if (allow) require(bytes(ISwapper(swapper).VERSION()).length > 0, "loans: invalid swapper");
        allow ? allowedSwappers.add(swapper) : allowedSwappers.remove(swapper);

        // it is possible to disallow and set as default at the same time. E.g., to unset the default
        // to zero. Worst case, if no swappers are allowed, loans can be cancelled and unwrapped.
        if (setDefault) defaultSwapper = swapper;

        emit SwapperSet(swapper, allow, setDefault);
    }

    // ----- INTERNAL MUTATIVE ----- //

    /**
     * @notice 内部函数：处理托管和非托管借贷的核心逻辑
     * @param underlyingAmount 要抵押的underlying资产数量
     * @param minLoanAmount 可接受的最小借贷金额
     * @param swapParams 交换参数
     * @param providerOffer 流动性提供者报价
     * @param usesEscrow 是否使用托管服务
     * @param escrowOffer 托管报价信息
     * @param escrowFees 托管费用
     * @return loanId 借贷NFT的ID
     * @return providerId 配对的provider NFT的ID
     * @return loanAmount 实际借贷金额
     */
    function _openLoan(
        uint underlyingAmount,        
        uint minLoanAmount,           
        SwapParams calldata swapParams,   
        ProviderOffer calldata providerOffer, 
        bool usesEscrow,              
        EscrowOffer memory escrowOffer,   
        uint escrowFees               
    ) internal returns (uint loanId, uint providerId, uint loanAmount) {
        
        // 检查当前合约是否被授权为指定资产对开启借贷
        // 这是第一层权限检查，确保合约本身有权限操作
        require(
            configHub.canOpenPair(address(underlying), address(cashAsset), address(this)),
            "loans: unsupported loans"
        );
        // taker NFT and provider NFT canOpen is checked in _swapAndMintCollar
        // escrow NFT canOpen is checked in _conditionalOpenEscrow

        // sanitize escrowFee in case usesEscrow is false.
        // Redundant since depends on internal logic, but more consistent with rest of escrow logic
        escrowFees = usesEscrow ? escrowFees : 0;
        // stack too deep        
        // 这是第一步：用户将资产存入合约
        underlying.safeTransferFrom(msg.sender, address(this), underlyingAmount + escrowFees);

        // handle optional escrow, must be done first, to use "supplier's" underlying in swap        // 处理可选的托管服务，必须在交换之前完成
        // in case of escrow 返回托管NFT合约地址和托管ID
        (EscrowSupplierNFT escrowNFT, uint escrowId) =
            _conditionalOpenEscrow(usesEscrow, underlyingAmount, escrowOffer, escrowFees);
        // stack too deep
        // 使用代码块避免"stack too deep"错误, Solidity有16个局部变量的限制
        {
            uint takerId; 
            // @dev Reentrancy assumption: no user manipulable state writes or reads BEFORE this call due to
            // potential untrusted calls during swapping, The only exception is taker.nextPositionId(), which
            // is why escrow's loanId is later validated in _escrowValidations.            
            
            // 执行交换和创建Collar头寸的核心逻辑
            // 返回：takerId, providerId, 实际借贷金额
            (takerId, providerId, loanAmount) =
                _swapAndMintCollar(underlyingAmount, providerOffer, swapParams);
            // despite the swap slippage check, explicitly check loanAmount, to avoid coupling and assumptions            
            // 尽管有交换滑点检查，仍然明确检查借贷金额
            // 这是为了避免耦合和假设，确保借贷金额满足用户要求
            require(loanAmount >= minLoanAmount, "loans: loan amount too low");
            // validate loanId
            // 验证借贷ID，确保ID唯一性
            loanId = _newLoanIdCheck(takerId);
        }
        // @dev these checks can only be done in the end of _openLoan, after both escrow and taker
        // positions exist
        // 注释说明：这些检查只能在_openLoan结束时进行
        // 因为需要等到托管和taker头寸都存在后才能验证
        if (usesEscrow) _escrowValidations(loanId, escrowNFT, escrowId);

        // store the loan opening data
        // 存储借贷开启的数据到存储映射中
        // 这些数据用于后续的借贷管理操作
        loans[loanId] = LoanStored({
            underlyingAmount: underlyingAmount,    // 原始抵押的underlying数量
            loanAmount: loanAmount,                // 实际借贷金额
            usesEscrow: usesEscrow,                // 是否使用托管
            escrowNFT: escrowNFT,                  // 托管NFT合约地址
            escrowId: SafeCast.toUint64(escrowId) // 托管ID，转换为64位无符号整数
         });

        // mint the loan NFT to the borrower, keep the taker NFT (with the same ID) in this contract
        // 将借贷NFT铸造给借款人
        // 同时将taker NFT（具有相同ID）保留在合约中
        // 注释说明：不使用_safeMint以避免重入攻击
        _mint(msg.sender, loanId); // @dev does not use _safeMint to avoid reentrancy

        // transfer the full loan amount on open
        // 在开启时转移全部借贷金额给用户
        // 用户立即获得借到的cash资产
        cashAsset.safeTransfer(msg.sender, loanAmount);

        // 发出借贷开启事件，记录所有关键信息
        // 包括借贷ID、借款人地址、抵押数量、借贷金额、托管状态等
        emit LoanOpened(
            loanId, msg.sender, underlyingAmount, loanAmount, usesEscrow, escrowId, address(escrowNFT)
        );
    }

    /// @dev swaps underlying to cash and mints collar position
    function _swapAndMintCollar(
        uint underlyingAmount,
        ProviderOffer calldata offer,
        SwapParams calldata swapParams
    ) internal returns (uint takerId, uint providerId, uint loanAmount) {
        (CollarProviderNFT providerNFT, uint offerId) = (offer.providerNFT, offer.id);

        require(
            configHub.canOpenPair(address(underlying), address(cashAsset), address(takerNFT)),
            "loans: unsupported taker"
        );
        // taker will check provider's canOpen as well, but we're using a view from it below so check too
        require(
            configHub.canOpenPair(address(underlying), address(cashAsset), address(providerNFT)),
            "loans: unsupported provider"
        );
        // taker is expected to check that providerNFT's assets match correctly

        // 0 underlying is later checked to mean non-existing loan, also prevents div-zero
        require(underlyingAmount != 0, "loans: invalid underlying amount");

        // swap underlying
        // @dev Reentrancy assumption: no user state writes or reads BEFORE the swapper call in _swap.
        // The only state reads before are owner-set state (e.g., pause and swapper allowlist).
        uint cashFromSwap = _swap(underlying, cashAsset, underlyingAmount, swapParams);

        /* @dev note on swap price manipulation:
        The swap price is only used for "pot sizing", but not for payouts division on expiry.
        Due to this, price manipulation *should* NOT leak value from provider / escrow / protocol,
        only from sender. But sender (borrower) is protected via a slippage parameter, and should
        use it to avoid MEV (if present).
        However, allowing extreme manipulation (self-sandwich) can introduce edge-cases, for example
        by taking a large escrow amount, but only a small collar position, which can violate some
        implicit integration assumptions. */
        // 确保交换价格与Oracle价格差异不超过10%
        _checkSwapPrice(cashFromSwap, underlyingAmount);


        // split the cash to loanAmount and takerLocked
        // this uses LTV === put strike percent, so the loan is the pre-exercised put (sent to user)
        // in the "Variable Prepaid Forward" (trad-fi) structure. The Collar paired position NFTs
        // implement the rest of the payout.
        uint ltvPercent = providerNFT.getOffer(offerId).putStrikePercent;
        loanAmount = ltvPercent * cashFromSwap / BIPS_BASE;
        // everything that remains is locked on the taker side in the collar position
        uint takerLocked = cashFromSwap - loanAmount;

        // open the paired taker and provider positions
        cashAsset.forceApprove(address(takerNFT), takerLocked);
        (takerId, providerId) = takerNFT.openPairedPosition(takerLocked, providerNFT, offerId);
    }

    /// @dev should be used for opening only. If used for close will prevent closing if slippage is too high.
    /// The swap price is only used for "pot sizing", but not for payouts division on expiry.
    /// The caller (user) is protected via a slippage parameter, and SHOULD use it to avoid MEV (if present).
    /// So, this check is just extra precaution and avoidance of extreme edge-cases.
    function _checkSwapPrice(uint cashFromSwap, uint underlyingAmount) internal view {
        ITakerOracle oracle = takerNFT.oracle();
        // get the equivalent amount of underlying the cash from swap is worth at oracle price
        uint underlyingFromCash = oracle.convertToBaseAmount(cashFromSwap, oracle.currentPrice());
        // calculate difference
        (uint a, uint b) = (underlyingAmount, underlyingFromCash);
        uint absDiff = a > b ? a - b : b - a;
        uint deviation = absDiff * BIPS_BASE / underlyingAmount; // checked on open to not be 0
        require(deviation <= MAX_SWAP_PRICE_DEVIATION_BIPS, "swap and oracle price too different");
    }

    /**
     * @dev swap logic with balance and slippage checks
     * @dev reentrancy assumption 1: _swap is called either before or after all internal user state
     * writes or reads. Such that if there's a reentrancy (e.g., via a malicious token in a
     * multi-hop route), it should NOT be able to take advantage of any inconsistent state.
     * @dev reentrancy assumption 2: contract does not hold funds. If the contract is changed to
     * hold funds at rest, and swap is allowed to reenter a method that increases funds at rest,
     * there can be a risk of double-counting - in that method, and in the balance update check below.
     * 
     * @notice 内部交换函数：执行资产交换逻辑，包含余额和滑点检查
     * @dev 重入攻击假设1：_swap在内部用户状态写入或读取之前或之后调用
     * 这样如果有重入攻击（例如通过多跳路由中的恶意代币），它无法利用任何不一致的状态
     * @dev 重入攻击假设2：合约不持有资金。如果合约被改为持有资金，且交换被允许重入增加资金的方法
     * 可能存在重复计算的风险 - 在该方法中，以及下面的余额更新检查中
     */
    function _swap(IERC20 assetIn, IERC20 assetOut, uint amountIn, SwapParams calldata swapParams)
        internal
        returns (uint amountOut)
    {
        // check swapper allowed
        // 检查交换器是否被允许使用
        require(isAllowedSwapper(swapParams.swapper), "loans: swapper not allowed");

        // @dev 0 amount swaps may revert (depending on swapper), short-circuit here instead of in
        // swappers to: reduce surface area for integration issues.
        // 0金额交换可能会回滚（取决于交换器），在这里短路而不是在交换器中
        // 目的是：减少集成问题的表面积
        if (amountIn == 0) {
            amountOut = 0;
        } else {
            // 记录交换前的余额，用于后续验证
            uint balanceBefore = assetOut.balanceOf(address(this));
            
            // approve the swapper
            // 授权交换器使用输入资产
            assetIn.forceApprove(swapParams.swapper, amountIn);

            /* @dev It may be tempting to simplify this by using an arbitrary call instead of a
            specific interface such as ISwapper. However:
            1. Using a specific interface is safer because it makes stealing approvals impossible.
            This is safer than depending only on the allowlist.
            2. An arbitrary call payload for a swap is more difficult to construct and inspect
            so requires more user trust on the FE.
            3. Swap's amountIn would need to be calculated off-chain exactly, which in case of closing
            the loan is problematic if position was not settled already (and so exact withdrawal amount
            is not known), so would require first settling, and then closing.

            The interface still allows arbitrary complexity via the extraData field if needed.
            
            注释：使用特定接口ISwapper而不是任意调用的原因：
            1. 使用特定接口更安全，因为它使窃取授权变得不可能。这比仅依赖白名单更安全。
            2. 交换的任意调用载荷更难构造和检查，所以需要前端更多的用户信任。
            3. 交换的amountIn需要链下精确计算，在关闭借贷时如果头寸尚未结算（因此确切提取金额未知）
               这会成问题，所以需要先结算，然后关闭。
            
            接口仍然通过extraData字段允许任意复杂性（如果需要）。
            */
            
            // 调用交换器的swap函数执行实际交换
            uint amountOutSwapper = ISwapper(swapParams.swapper).swap(
                assetIn, assetOut, amountIn, swapParams.minAmountOut, swapParams.extraData
            );
            
            // Calculate the actual amount received
            // 计算实际收到的金额（通过余额变化）
            amountOut = assetOut.balanceOf(address(this)) - balanceBefore;
            
            // check balance is updated as expected and as reported by swapper (no other balance changes)
            // @dev important check for preventing swapper reentrancy (if using e.g., arbitrary call swapper)
            // 检查余额是否按预期更新，并与交换器报告的数量一致（没有其他余额变化）
            // 这是防止交换器重入攻击的重要检查（如果使用例如任意调用交换器）
            require(amountOut == amountOutSwapper, "loans: balance update mismatch");
        }

        // check amount is as expected by user
        // 检查金额是否符合用户预期（滑点保护）
        require(amountOut >= swapParams.minAmountOut, "loans: slippage exceeded");
    }

    function _settleAndWithdrawTaker(uint loanId) internal returns (uint withdrawnAmount) {
        uint takerId = _takerId(loanId);

        // position could have been settled by anyone already
        (, bool settled) = takerNFT.expirationAndSettled(takerId);
        if (!settled) {
            /// @dev this will revert on: too early, no position, calculation issues, ...
            takerNFT.settlePairedPosition(takerId);
        }

        /// @dev because taker NFT is held by this contract, this could not have been called already
        withdrawnAmount = takerNFT.withdrawFromSettled(takerId);
    }

    function _executeRoll(uint loanId, RollOffer calldata rollOffer, int minToUser)
        internal
        returns (uint newTakerId, int toTaker, int rollFee)
    {
        (Rolls rolls, uint rollId) = (rollOffer.rolls, rollOffer.id);
        // check this rolls contract is allowed
        require(
            configHub.canOpenPair(address(underlying), address(cashAsset), address(rolls)),
            "loans: unsupported rolls"
        );
        // ensure it's the right takerNFT in case of multiple takerNFTs for an asset pair
        require(address(rolls.takerNFT()) == address(takerNFT), "loans: rolls takerNFT mismatch");
        // offer status (active) is not checked, also since rolls should check / fail

        // for balance check at the end
        uint initialBalance = cashAsset.balanceOf(address(this));

        // get transfer amount and fee from rolls
        IRolls.PreviewResults memory preview = rolls.previewRoll(rollId, takerNFT.currentOraclePrice());
        rollFee = preview.rollFee;

        // pull cash
        if (preview.toTaker < 0) {
            uint fromUser = uint(-preview.toTaker); // will revert for type(int).min
            // pull cash first, because rolls will try to pull it (if needed) from this contract
            // @dev assumes approval
            cashAsset.safeTransferFrom(msg.sender, address(this), fromUser);
            // allow rolls to pull this cash
            cashAsset.forceApprove(address(rolls), fromUser);
        }

        // approve the taker NFT (held in this contract) for rolls to pull
        takerNFT.approve(address(rolls), _takerId(loanId));
        // execute roll
        (newTakerId,, toTaker,) = rolls.executeRoll(rollId, minToUser);
        // check return value matches preview, which is used for updating the loan and pulling cash
        require(toTaker == preview.toTaker, "loans: unexpected transfer amount");
        // check slippage (would have been checked in Rolls as well)
        require(toTaker >= minToUser, "loans: roll transfer < minToUser");
        // check taker ID received
        require(takerNFT.ownerOf(newTakerId) == address(this), "loans: new taker ID not received");

        // transfer cash if should have received any
        if (toTaker > 0) {
            // @dev this will revert if rolls contract didn't actually pay above
            cashAsset.safeTransfer(msg.sender, uint(toTaker));
        }

        // there should be no balance change for the contract (which might happen e.g., if rolls contract
        // overestimated amount to pull from user and under-reported return value)
        require(cashAsset.balanceOf(address(this)) == initialBalance, "loans: contract balance changed");
    }

    // ----- Conditional escrow mutative methods ----- //

    function _conditionalOpenEscrow(bool usesEscrow, uint escrowed, EscrowOffer memory offer, uint fees)
        internal
        returns (EscrowSupplierNFT escrowNFT, uint escrowId)
    {
        if (usesEscrow) {
            escrowNFT = offer.escrowNFT;
            // check asset matches
            require(escrowNFT.asset() == underlying, "loans: escrow asset mismatch");
            // whitelisted only
            require(
                configHub.canOpenSingle(address(underlying), address(escrowNFT)), "loans: unsupported escrow"
            );

            // @dev underlyingAmount and fee were pulled already before calling this method
            underlying.forceApprove(address(escrowNFT), escrowed + fees);
            escrowId = escrowNFT.startEscrow({
                offerId: offer.id,
                escrowed: escrowed,
                fees: fees,
                loanId: takerNFT.nextPositionId() // @dev checked later in _escrowValidations
             });
            // @dev no balance checks because contract holds no funds, mismatch will cause reverts
        } else {
            // returns default empty values
        }
    }

    /// @dev escrow switch during roll
    function _conditionalSwitchEscrow(Loan memory prevLoan, uint offerId, uint newLoanId, uint newFees)
        internal
        returns (uint newEscrowId)
    {
        if (prevLoan.usesEscrow) {
            EscrowSupplierNFT escrowNFT = prevLoan.escrowNFT;
            // check this escrow is still allowed
            require(
                configHub.canOpenSingle(address(underlying), address(escrowNFT)), "loans: unsupported escrow"
            );

            underlying.safeTransferFrom(msg.sender, address(this), newFees);
            underlying.forceApprove(address(escrowNFT), newFees);
            uint feesRefund;
            (newEscrowId, feesRefund) = escrowNFT.switchEscrow({
                releaseEscrowId: prevLoan.escrowId,
                offerId: offerId,
                newFees: newFees,
                newLoanId: newLoanId
            });

            // check escrow and loan have matching fields
            _escrowValidations(newLoanId, escrowNFT, newEscrowId);

            // send potential interest fee refund
            underlying.safeTransfer(msg.sender, feesRefund);
        } else {
            // returns default empty value
        }
    }

    // @dev used in close
    function _conditionalEndEscrow(Loan memory loan, uint fromSwap) internal returns (uint underlyingOut) {
        if (loan.usesEscrow) {
            (EscrowSupplierNFT escrowNFT, uint escrowId) = (loan.escrowNFT, loan.escrowId);

            // only need to return escrowed, since fees were paid / held upfront
            uint escrowed = escrowNFT.getEscrow(escrowId).escrowed;
            // if owing more than swapped, use all, otherwise just what's owed
            uint toEscrow = Math.min(fromSwap, escrowed);
            // if owing less than swapped, left over gains are for the borrower
            uint leftOver = fromSwap - toEscrow;

            underlying.forceApprove(address(escrowNFT), toEscrow);
            // fromEscrow is what escrow returns after deducting any shortfall and adding refunds:
            // - a refund of principal is expected since escrow should return the user's
            // original funds (minus shortfall)
            // - should be a late fee refund (full or partial), if before end of grace period
            // - should not be any interest fee refund here, because this is after expiry
            uint fromEscrow = escrowNFT.endEscrow(escrowId, toEscrow);
            // @dev no balance checks because contract holds no funds, mismatch will cause reverts

            // the released and the leftovers to be sent to borrower. Zero-value-transfer is allowed
            underlyingOut = fromEscrow + leftOver;

            emit EscrowSettled(escrowId, toEscrow, fromEscrow, leftOver);
        } else {
            underlyingOut = fromSwap;
        }
    }

    function _conditionalCheckAndCancelEscrow(uint loanId) internal {
        Loan memory loan = getLoan(loanId);
        // only check and release if escrow was used
        if (loan.usesEscrow) {
            (EscrowSupplierNFT escrowNFT, uint escrowId) = (loan.escrowNFT, loan.escrowId);
            bool escrowReleased = escrowNFT.getEscrow(escrowId).released;
            /* Allow cancelling in all cases.

            1. Not released, prior to expiry.

            2. Not released, after expiry. Late fees will be accounted by the escrow contract.
            This allows unwrapping during min-grace-period, despite late-fee being zero then.
            This allows the borrower to wait until the min-grace end to cancel, which delays the escrow
            without compensating with late fees, for this short period.
            However, this is symmetric to them being able to close during that period without paying
            late fees. Escrow owners should take this into account when calculating their offer terms.
            Alternatively, a different escrow implementation can use different logic:
            for example, a shorter, or no min-grace period, or can charge regular interest during it.

            3. If escrow was released: no-op to handle the case of escrow owner
              calling escrowNFT.seizeEscrow() after end of grace period.
              In that case, closing is not possible, because escrow is released already, and user is
              very late to close, so we send them the takerId to withdraw cash if any is left.
            */

            if (!escrowReleased) {
                // if not released, release the user funds to the supplier since the user will not repay
                // the loan. Late fees are held upfront if relevant. Repayment is 0 since there was
                // no swap. There may be an interest fee refund for the borrower (if before expiry).
                // @dev In immediate cancellation: NOT all escrow fee is refunded. Part of interest fee
                // is non-refundable to prevent DoS of escrow offers by cycling them into withdrawals.
                uint feeRefund = escrowNFT.endEscrow(escrowId, 0);
                // @dev no balance checks because contract holds no funds, mismatch will cause reverts
                underlying.safeTransfer(msg.sender, feeRefund);

                emit EscrowSettled(escrowId, 0, feeRefund, 0);
            }
        }
    }

    // ----- INTERNAL VIEWS ----- //

    /* @dev note that ERC721 approval system should NOT be used instead of this limited system because
    it would grant the keeper much more powers than needed, since in case of compromise it
    would be able to pull all NFTs from exposed users, instead of currently being able to exploit only
    their loans that are about to be closed, and only via a more complex "slippage" attack.
    */
    function _isSenderOrKeeperFor(address authorizedSender, uint loanId) internal view returns (bool) {
        return msg.sender == authorizedSender || msg.sender == keeperApprovedFor[authorizedSender][loanId];
    }

    function _newLoanIdCheck(uint takerId) internal view returns (uint loanId) {
        // @dev loanIds correspond to takerIds they wrap for simplicity. this is ok because takerId is
        // unique (for the single taker contract wrapped here) and the ID is minted by this contract
        loanId = takerId;
        // @dev because we use the takerId for the loanId (instead of having separate IDs), we should
        // check that the ID is not yet taken. This should not be possible, since takerId should mint
        // new IDs correctly, but can be checked for completeness.
        // @dev non-zero should be ensured when opening loan
        require(loans[loanId].underlyingAmount == 0, "loans: loanId taken");
    }

    function _takerId(uint loanId) internal pure returns (uint takerId) {
        // existence is not checked, because this is assumed to be used only for valid loanId
        takerId = loanId;
    }

    function _expiration(uint loanId) internal view returns (uint expiration) {
        (expiration,) = takerNFT.expirationAndSettled(_takerId(loanId));
    }

    /*
    @dev Note that if roll price was outside of the initial put-call range the newLoanAmount
    may not correspond to the initial LTV (putStrikePercent) w.r.t, to the new position:
        newLoanAmount / (newLoanAmount + takerLocked) <> putStrikePercent.
    And the value in underlying terms will also not remain roughly constant.
    - If the price went above call strike, the LTV and underlying-exposure will be lower.
    - If the price went below put strike, the LTV and underlying-exposure will be higher.
    Specifically this behavior should be taken into account w.r.t. to flexible roll implementations
    (e.g., to different terms) to avoid assuming constant exposure or valid LTV.
    */
    function _loanAmountAfterRoll(int fromRollsToUser, int rollFee, uint prevLoanAmount)
        internal
        pure
        returns (uint newLoanAmount)
    {
        // The transfer subtracted the fee (see Rolls calculations), so it needs
        // to be added back. The fee is not part of the position, so that if price hasn't changed,
        // after rolling, the updated position (loan amount + takerLocked) would still be equivalent
        // to the initial underlying (if it was initially equivalent, depending on the initial swap)
        // Example: toTaker       = position-gain - fee = 100 - 1 = 99
        //      So: position-gain = toTaker       + fee = 99  + 1 = 100
        int loanChange = fromRollsToUser + rollFee;
        if (loanChange < 0) {
            uint repayment = uint(-loanChange); // will revert for type(int).min
            require(repayment <= prevLoanAmount, "loans: repayment larger than loan");
            // if the borrower manipulated (sandwiched) their open swap price to be very low, they
            // may not be able to roll now. Rolling is optional, so this is not a problem.
            newLoanAmount = prevLoanAmount - repayment;
        } else {
            newLoanAmount = prevLoanAmount + uint(loanChange);
        }
    }

    // ----- Internal escrow views ----- //

    // @dev this can be called when both escrow and taker positions exist
    function _escrowValidations(uint loanId, EscrowSupplierNFT escrowNFT, uint escrowId) internal view {
        IEscrowSupplierNFT.Escrow memory escrow = escrowNFT.getEscrow(escrowId);
        // taker.nextPositionId() view was used to create escrow (in open), but it was used before
        // external calls, so we need to ensure it matches still (was not skipped by reentrancy).
        // For rolls this check is not really needed since no untrusted calls are made between
        // switching escrow and this code.
        require(escrow.loanId == loanId, "loans: unexpected loanId");
        // check expirations are equal to ensure no duration mismatch between escrow and collar
        // @dev if this constraint is removed (escrow duration can be longer than loan), care should
        // be taken around the escrow interest refund limit
        require(escrow.expiration == _expiration(loanId), "loans: duration mismatch");
    }
}
