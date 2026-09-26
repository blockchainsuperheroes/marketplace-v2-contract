// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PentagonPrizeLockerOpen} from "../src/PrizeLockerOpen.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockPFP is ERC721 {
    constructor() ERC721("Azuki", "AZUKI") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract PrizeLockerOpenTest is Test {
    PentagonPrizeLockerOpen locker;
    MockPFP nft;
    uint256 constant ADMIN_PK = 0xA0A0;
    uint256 constant OTHER_PK = 0xBAD;
    address admin = vm.addr(ADMIN_PK);
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice"); // seller 1
    address bob = makeAddr("bob"); // seller 2
    address winner = makeAddr("winner");

    function setUp() public {
        nft = new MockPFP();
        locker = new PentagonPrizeLockerOpen(admin, keeper);
        nft.mint(alice, 1);
        nft.mint(bob, 2);
        vm.prank(alice); nft.setApprovalForAll(address(locker), true);
        vm.prank(bob); nft.setApprovalForAll(address(locker), true);
    }

    function _sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function test_anyHolderChecksIn_recordedAsDepositor() public {
        vm.prank(alice); uint256 a = locker.checkIn(address(nft), 1);
        vm.prank(bob); uint256 b = locker.checkIn(address(nft), 2);
        (, , address da, ) = locker.locks(a);
        (, , address db, ) = locker.locks(b);
        assertEq(da, alice);
        assertEq(db, bob);
        assertEq(nft.ownerOf(1), address(locker));
    }

    function test_cannotCheckInSomeoneElsesNFT() public {
        vm.prank(bob);
        vm.expectRevert(PentagonPrizeLockerOpen.NotHeld.selector);
        locker.checkIn(address(nft), 1); // alice's token, bob is approved-for-nothing
    }

    function test_strayTransferCannotBeAdoptedByAnyone() public {
        vm.prank(alice); nft.transferFrom(alice, address(locker), 1); // mistaken plain transfer
        vm.prank(bob);
        vm.expectRevert(PentagonPrizeLockerOpen.NotHeld.selector);
        locker.checkIn(address(nft), 1);
    }

    function test_withdrawOnlyThatLocksDepositor_withAdminSig() public {
        vm.prank(alice); uint256 a = locker.checkIn(address(nft), 1);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.withdrawDigest(a, dl));
        vm.prank(bob);
        vm.expectRevert(PentagonPrizeLockerOpen.NotDepositor.selector);
        locker.withdraw(a, dl, sig);
        vm.prank(alice);
        locker.withdraw(a, dl, sig);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_depositorCannotWithdrawAlone() public {
        vm.prank(alice); uint256 a = locker.checkIn(address(nft), 1);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory selfSig = _sign(OTHER_PK, locker.withdrawDigest(a, dl));
        vm.prank(alice);
        vm.expectRevert(PentagonPrizeLockerOpen.BadAdminSig.selector);
        locker.withdraw(a, dl, selfSig);
    }

    function test_releaseNeedsKeeperAndAdminSig() public {
        vm.prank(alice); uint256 a = locker.checkIn(address(nft), 1);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.releaseDigest(a, winner, dl));
        vm.prank(alice);
        vm.expectRevert(PentagonPrizeLockerOpen.NotKeeper.selector);
        locker.release(a, winner, dl, sig);
        vm.prank(keeper);
        locker.release(a, winner, dl, sig);
        assertEq(nft.ownerOf(1), winner);
    }

    function test_rolesRotationDelayed() public {
        address k2 = makeAddr("k2");
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(ADMIN_PK, locker.proposeRolesDigest(admin, k2, dl));
        locker.proposeRoles(admin, k2, dl, sig);
        vm.expectRevert(PentagonPrizeLockerOpen.TooEarly.selector);
        locker.executeRoles("");
        vm.warp(block.timestamp + 48 hours);
        locker.executeRoles("");
        assertEq(locker.keeper(), k2);
    }

    function test_directSafeTransferRejected() public {
        vm.prank(alice);
        vm.expectRevert(PentagonPrizeLockerOpen.UnexpectedTransfer.selector);
        nft.safeTransferFrom(alice, address(locker), 1);
    }
}
