pragma solidity ^0.5.13;

import "../TrueCurrencies/TrueRewardBackedToken.sol";
import "./IAToken.sol";
import "./ILendingPool.sol";
import "../TrueCurrencies/Proxy/OwnedUpgradeabilityProxy.sol";
import "./FinancialOpportunity.sol";
import "./ILendingPoolCore.sol";
import "../TrueCurrencies/modularERC20/InstantiatableOwnable.sol";

/**
 * @title AaveFinancialOpportunity
 * @dev Financial Opportunity to earn TrueUSD with Aave.
 * stakeToken = aTUSD on Aave
 * We assume perTokenValue always increases
 */
contract AaveFinancialOpportunity is FinancialOpportunity, InstantiatableOwnable {
    using SafeMath for uint256;

    IAToken public stakeToken; // aToken
    ILendingPool public lendingPool; // lending pool
    TrueRewardBackedToken public token; // TrueRewardBackedToken (TrueUSD)

    modifier onlyProxyOwner() {
        require(msg.sender == proxyOwner(), "only proxy owner");
        _;
    }

    /**
     * @dev Set up Aave Opportunity
     */
    function configure(
        IAToken _stakeToken,            // aToken
        ILendingPool _lendingPool,      // lendingPool interface
        TrueRewardBackedToken _token,   // TrueRewardBackedToken
        address _owner                  // owner
    ) public onlyProxyOwner {
        stakeToken = _stakeToken;
        lendingPool = _lendingPool;
        token = _token;
        owner = _owner;
    }

    function proxyOwner() public view returns(address) {
        return OwnedUpgradeabilityProxy(address(this)).proxyOwner();
    }

    function perTokenValue() public view returns(uint256) {
        ILendingPoolCore core = ILendingPoolCore(lendingPool.core());
        return core.getReserveNormalizedIncome(address(token)).div(10**(27-18));
    }

    function getBalance() public view returns(uint256) {
        return stakeToken.balanceOf(address(this));
    }

    /** @dev Return value of stake in TUSD */
    function getValueInStake(uint256 _amount) public view returns(uint256) {
        return _amount.mul(10**18).div(perTokenValue());
    }

    /** @dev Deposit TUSD into Aave */
    function deposit(address _from, uint256 _amount) external onlyOwner returns(uint256) {
        require(token.transferFrom(_from, address(this), _amount), "transfer from failed");
        require(token.approve(address(lendingPool), _amount), "approve failed");

        uint256 balanceBefore = getBalance();
        lendingPool.deposit(address(token), _amount, 0);
        uint256 balanceAfter = getBalance();

        return getValueInStake(balanceAfter.sub(balanceBefore));
    }

    /** @dev Helper to withdraw TUSD from Aave */
    function _withdraw(address _to, uint256 _amount) internal returns(uint256) {
        uint256 balanceBefore = token.balanceOf(address(this));
        stakeToken.redeem(_amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 fundsWithdrawn = balanceAfter.sub(balanceBefore);

        require(token.transfer(_to, fundsWithdrawn), "transfer failed");

        return getValueInStake(fundsWithdrawn);
    }

    function withdrawTo(address _to, uint256 _amount) external onlyOwner returns(uint256) {
        return _withdraw(_to, _amount);
    }

    function withdrawAll(address _to) external onlyOwner returns(uint256) {
        return _withdraw(_to, getBalance());
    }

    function() external payable {
    }
}