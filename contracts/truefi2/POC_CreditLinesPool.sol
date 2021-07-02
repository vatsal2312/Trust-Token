// SPDX-License-Identifier: MIT
pragma solidity 0.6.10;

import "./TrueFiPool2.sol";

/**
This is an unoptimised Proof of Concept for calculating interest rates for credit lines
*/
contract CreditLinesPool is TrueFiPool2 {
    uint16 constant basicRate = 1000; // don't care for now

    struct Checkpoint {
        mapping(address => uint256) interests;
        mapping(address => uint16) rates;
        uint256 timestamp;
        uint256 totalInterest; // total interest on last checkpoint
        uint256 totalPendingYearlyInterest; // Σ interests_i * rates_i
        uint256 poolValue;
        mapping(address => uint256) borrowed;
        uint256 totalBorrowed;
        address[] borrowers;
    }
    Checkpoint public cp;

    function interest(address borrower) public view returns (uint256) {
        return
            cp.interests[borrower].add(
                uint256(cp.rates[borrower]).mul(cp.borrowed[borrower]).mul(block.timestamp - cp.timestamp).div(365 days)
            );
    }

    function totalInterest() public view returns (uint256) {
        return cp.totalInterest.add(cp.totalPendingYearlyInterest.mul(block.timestamp - cp.timestamp).div(365 days));
    }

    function poolValue() public override view returns (uint256) {
        return super.poolValue().add(totalInterest());
    }

    function utilization() public view returns (uint16) {
        uint256 t_interest = totalInterest();
        return uint16((t_interest.add(cp.totalBorrowed)).mul(10000).div(cp.poolValue + t_interest - cp.totalInterest));
    }

    function utilizationAdjustment(uint16 util) public pure returns (uint16) {
        if (util < 5000) return util / 10;
        if (util < 8000) return ((util * 2) / 10) - 950;
        return ((util * 3) / 2) - 11350;
    }

    function rate(address borrower) public view returns (uint16) {
        return basicRate + utilizationAdjustment(utilization());
    }

    function checkpoint() public {
        uint256 interestTotal;
        uint256 totalPendingInterest;
        for (uint16 i = 0; i < cp.borrowers.length; i++) {
            address borrower = cp.borrowers[i];
            uint16 borrowerRate = rate(borrower);
            uint256 pendingInterest = uint256(borrowerRate).mul(cp.borrowed[borrower]);
            cp.interests[borrower] = cp.interests[borrower].add(pendingInterest.mul(block.timestamp - cp.timestamp).div(365 days));
            totalPendingInterest += pendingInterest;
            interestTotal += cp.interests[borrower];
            cp.rates[borrower] = borrowerRate;
        }
        cp.totalInterest = interestTotal;
        cp.poolValue = poolValue();
        cp.totalPendingYearlyInterest = totalPendingInterest;
        cp.timestamp = block.timestamp;
    }

    function join(uint256 amount) public override {
        super.join(amount);
        checkpoint();
    }

    function exit(uint256 amount) public override {
        super.exit(amount);
        checkpoint();
    }

    function liquidExit(uint256 amount) public override {
        super.liquidExit(amount);
        checkpoint();
    }

    function borrowCreditLine(uint256 amount) external {
        if (cp.borrowed[msg.sender] == 0) {
            cp.borrowers.push(msg.sender);
        }
        cp.borrowed[msg.sender] += amount;
        cp.totalBorrowed += amount;
        checkpoint();
    }

    function returnCreditLine(uint256 amount) external {
        cp.borrowed[msg.sender] = cp.borrowed[msg.sender].sub(amount);
        cp.totalBorrowed = cp.totalBorrowed.sub(amount);
        checkpoint();
    }
}
