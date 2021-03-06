// SPDX-License-Identifier: MIT
pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20} from "../common/UpgradeableERC20.sol";
import {DeficiencyToken} from "./DeficiencyToken.sol";
import {IDeficiencyToken} from "./interface/IDeficiencyToken.sol";
import {UpgradeableClaimable} from "../common/UpgradeableClaimable.sol";
import {ILoanToken2} from "./interface/ILoanToken2.sol";
import {ITrueFiPool2} from "./interface/ITrueFiPool2.sol";
import {ILoanFactory2} from "./interface/ILoanFactory2.sol";
import {ILiquidator2} from "./interface/ILiquidator2.sol";
import {I1Inch3} from "./interface/I1Inch3.sol";
import {OneInchExchange} from "./libraries/OneInchExchange.sol";
import {ISAFU} from "./interface/ISAFU.sol";

contract SAFU is ISAFU, UpgradeableClaimable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IDeficiencyToken;
    using SafeERC20 for ERC20;
    using OneInchExchange for I1Inch3;

    // ================ WARNING ==================
    // ===== THIS CONTRACT IS INITIALIZABLE ======
    // === STORAGE VARIABLES ARE DECLARED BELOW ==
    // REMOVAL OR REORDER OF VARIABLES WILL RESULT
    // ========= IN STORAGE CORRUPTION ===========

    ILoanFactory2 public loanFactory;
    ILiquidator2 public liquidator;
    I1Inch3 public _1Inch;

    mapping(ILoanToken2 => IDeficiencyToken) public override deficiencyToken;
    mapping(address => uint256) public override poolDeficit;

    // ======= STORAGE DECLARATION END ============

    /**
     * @dev Emitted when a loan is redeemed
     * @param loan Loan that has been liquidated
     * @param burnedAmount Amount of loan tokens that were burned
     * @param redeemedAmount Amount of tokens that were received
     */
    event Redeemed(ILoanToken2 loan, uint256 burnedAmount, uint256 redeemedAmount);

    /**
     * @dev Emitted when a loan gets liquidated
     * @param loan Loan that has been liquidated
     * @param repaid Amount repaid to the pool
     * @param deficiencyToken Deficiency token representing a deficit that is owed to the pool by SAFU
     * @param deficit Deficit amount that SAFU still owes the pool
     */
    event Liquidated(ILoanToken2 loan, uint256 repaid, IDeficiencyToken deficiencyToken, uint256 deficit);

    /**
     * @dev Emitted when a loan deficit is reclaimed
     * @param loan Defaulted loan, which deficit was reclaimed
     * @param reclaimed Amount reclaimed by the pool
     */
    event Reclaimed(ILoanToken2 loan, uint256 reclaimed);

    function initialize(
        ILoanFactory2 _loanFactory,
        ILiquidator2 _liquidator,
        I1Inch3 __1Inch
    ) public initializer {
        UpgradeableClaimable.initialize(msg.sender);
        loanFactory = _loanFactory;
        liquidator = _liquidator;
        _1Inch = __1Inch;
    }

    /**
     * @dev Liquidates a defaulted Loan, withdraws a portion of tru from staking pool
     * then tries to cover the loan with own funds, to compensate TrueFiPool
     * If SAFU does not have enough funds, deficit is saved to be redeemed later
     * @param loan Loan to be liquidated
     */
    function liquidate(ILoanToken2 loan) external {
        require(loanFactory.isLoanToken(address(loan)), "SAFU: Unknown loan");
        require(loan.status() == ILoanToken2.Status.Defaulted, "SAFU: Loan is not defaulted");

        ITrueFiPool2 pool = ITrueFiPool2(loan.pool());
        IERC20 token = IERC20(pool.token());

        liquidator.liquidate(loan);
        pool.liquidate(loan);
        uint256 owedToPool = loan.debt().mul(tokenBalance(loan)).div(loan.totalSupply());
        uint256 safuTokenBalance = tokenBalance(token);

        uint256 deficit = 0;
        uint256 toTransfer = owedToPool;
        if (owedToPool > safuTokenBalance) {
            deficit = owedToPool.sub(safuTokenBalance);
            toTransfer = safuTokenBalance;
            deficiencyToken[loan] = new DeficiencyToken(loan, deficit);
            poolDeficit[address(loan.pool())] = poolDeficit[address(loan.pool())].add(deficit);
        }
        token.safeTransfer(address(pool), toTransfer);
        emit Liquidated(loan, toTransfer, deficiencyToken[loan], deficit);
    }

    /**
     * @dev Returns SAFU's balance of a specific token
     * @param token A token which balance is to be returned
     */
    function tokenBalance(IERC20 token) public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Redeems a loan for underlying repaid debt
     * @param loan Loan token to be redeemed
     */
    function redeem(ILoanToken2 loan) public onlyOwner {
        uint256 amountToBurn = tokenBalance(loan);
        uint256 balanceBeforeRedeem = tokenBalance(loan.token());
        loan.redeem(amountToBurn);
        uint256 redeemedAmount = tokenBalance(loan.token()).sub(balanceBeforeRedeem);
        emit Redeemed(loan, amountToBurn, redeemedAmount);
    }

    /**
     * @dev Reclaims deficit funds, after a loan is repaid and transfers them to the pool
     * @param loan Loan with a deficit to be reclaimed
     * @param amount Amount of deficiency tokens to be reclaimed
     */
    function reclaim(ILoanToken2 loan, uint256 amount) external override {
        require(tokenBalance(loan) == 0, "SAFU: Loan has to be fully redeemed by SAFU");
        IDeficiencyToken dToken = deficiencyToken[loan];
        require(dToken.balanceOf(msg.sender) > 0, "SAFU: Sender does not have deficiency tokens to be reclaimed");

        poolDeficit[address(loan.pool())] = poolDeficit[address(loan.pool())].sub(amount);
        dToken.safeTransferFrom(msg.sender, address(this), amount);
        dToken.burn(amount);
        loan.token().safeTransfer(msg.sender, amount);

        emit Reclaimed(loan, amount);
    }

    /**
     * @dev Swap any asset owned by SAFU to any other asset, using 1inch protocol
     */
    function swap(bytes calldata data, uint256 minReturnAmount) public onlyOwner {
        (I1Inch3.SwapDescription memory swapResult, uint256 returnAmount) = _1Inch.exchange(data);
        require(swapResult.dstReceiver == address(this), "SAFU: Receiver is not SAFU");
        require(returnAmount >= minReturnAmount, "SAFU: Not enough tokens returned from swap");
    }
}
