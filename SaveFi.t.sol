// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../contracts/SaveFi.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf; mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true; }
}

contract SaveFiTest is Test {
    SaveFiFactory f; MockToken usdt; SaveFiCircle c;
    address[3] u = [address(0xA1), address(0xB2), address(0xC3)];
    uint256 constant AMT = 100e6;

    function setUp() public {
        usdt = new MockToken();
        address[] memory t = new address[](1); t[0] = address(usdt);
        f = new SaveFiFactory(t);
        for (uint256 i; i < 3; i++) { usdt.mint(u[i], 10_000e6); }
    }

    function _make() internal {
        Params memory p = Params("Test", address(usdt), AMT, 7 days, 1 days, 3, 500, 1000, 3, false, 900e6);
        vm.prank(u[0]); c = SaveFiCircle(f.createCircle(p));
        for (uint256 i; i < 3; i++) { vm.startPrank(u[i]); usdt.approve(address(c), type(uint256).max); c.join(); vm.stopPrank(); }
    }
    function _payRound(uint256 r) internal { for (uint256 i; i < 3; i++) { vm.prank(u[i]); c.contribute(r); } }

    function test_NoDuplicateContribution() public {
        _make();
        vm.prank(u[0]); c.contribute(0);
        vm.prank(u[0]); vm.expectRevert("already paid"); c.contribute(0);
    }
    function test_CannotPayFutureRoundOrAsOutsider() public {
        _make();
        vm.prank(u[0]); vm.expectRevert("round not open"); c.contribute(1);
        vm.prank(address(0xDEAD)); vm.expectRevert("not member"); c.contribute(0);
    }
    function test_LateFeeAfterDeadline() public {
        _make();
        vm.warp(block.timestamp + 8 days);
        vm.prank(u[0]); c.contribute(0);                    // round 0 deadline passed: 5% fee
        assertEq(usdt.balanceOf(u[0]), 10_000e6 - AMT - AMT / 20);
        (, , , uint16 late, ) = c.mem(u[0]); assertEq(late, 1);
    }
    function test_GoalEarlyExitPenaltyAndFinalShare() public {
        _make();
        _payRound(0);
        vm.prank(u[2]); c.leave();                          // 10% penalty
        assertEq(usdt.balanceOf(u[2]), 10_000e6 - AMT / 10);
        vm.warp(block.timestamp + 22 days);
        vm.prank(u[0]); c.withdraw();
        assertGt(usdt.balanceOf(u[0]), 10_000e6);           // got share of penalty
        vm.prank(u[0]); vm.expectRevert("no balance"); c.withdraw();
    }
    function test_CancelOpenAndActiveRefunds() public {
        _make();
        _payRound(0);
        vm.prank(u[0]); vm.expectRevert("pause first"); c.cancel();
        vm.prank(u[0]); c.setPaused(true); vm.prank(u[0]); c.cancel();
        vm.prank(u[2]); c.refund();
        assertEq(usdt.balanceOf(u[2]), 10_000e6);
        vm.prank(u[2]); vm.expectRevert("n/a"); c.refund();
    }
    function test_FactoryEmergencyPause() public {
        _make();
        f.emergencyPause(address(c), true);
        vm.prank(u[0]); vm.expectRevert("inactive"); c.contribute(0);
    }

    function _pot() internal returns (SavingsPot p) {
        vm.prank(u[0]); p = SavingsPot(f.createPot("Laptop", address(usdt), 300e6, block.timestamp + 30 days, 1e6));
        for (uint256 i; i < 3; i++) { vm.prank(u[i]); usdt.approve(address(p), type(uint256).max); }
    }
    function test_PotOthersContributeOwnerWithdrawsAfterTarget() public {
        SavingsPot p = _pot();
        vm.prank(u[1]); p.contribute(100e6); vm.prank(u[2]); p.contribute(200e6);
        vm.prank(u[1]); vm.expectRevert("beneficiary only"); p.withdraw(1e6);
        vm.prank(u[0]); p.withdraw(300e6);
        assertEq(usdt.balanceOf(u[0]), 10_300e6);
        vm.prank(u[0]); vm.expectRevert("amount"); p.withdraw(1);
    }
    function test_PotLockedBeforeTargetOrDate() public {
        SavingsPot p = _pot();
        vm.prank(u[1]); p.contribute(10e6);
        vm.prank(u[0]); vm.expectRevert("locked"); p.withdraw(1e6);
        vm.warp(block.timestamp + 31 days);
        vm.prank(u[0]); p.withdraw(10e6);
    }
    function test_PotCancelRefundsContributors() public {
        SavingsPot p = _pot();
        vm.prank(u[1]); p.contribute(50e6);
        vm.prank(u[0]); p.cancel();
        vm.prank(u[1]); p.refund();
        assertEq(usdt.balanceOf(u[1]), 10_000e6);
        vm.prank(u[1]); vm.expectRevert("nothing"); p.refund();
    }
}
