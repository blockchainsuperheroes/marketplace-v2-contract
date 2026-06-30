// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PentagonPrivateSale} from "../src/PrivateSale.sol";

contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setApprovalForAll(address op, bool ok) external { isApprovedForAll[msg.sender][op] = ok; }

    function safeTransferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "wrong owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract PrivateSaleTest is Test {
    PentagonPrivateSale ps;
    MockNFT nft;
    MockToken wpc;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    uint256 constant TID = 7;

    function setUp() public {
        ps = new PentagonPrivateSale();
        nft = new MockNFT();
        wpc = new MockToken();
        nft.mint(seller, TID);
        vm.prank(seller);
        nft.setApprovalForAll(address(ps), true);
        vm.deal(buyer, 100 ether);
    }

    function _create(address pay) internal returns (uint256 id) {
        vm.prank(seller);
        id = ps.createPrivateSale(address(nft), TID, 2 ether, buyer, pay);
    }

    function testExecuteNativeNoFee() public {
        uint256 id = _create(address(0));
        vm.prank(buyer);
        ps.executePrivateSale{value: 2 ether}(id);
        assertEq(nft.ownerOf(TID), buyer);
        assertEq(seller.balance, 2 ether); // full price, NO fee
        assertEq(buyer.balance, 98 ether);
    }

    function testExecuteErc20NoFee() public {
        uint256 id = _create(address(wpc));
        wpc.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        wpc.approve(address(ps), 5 ether);
        ps.executePrivateSale(id);
        vm.stopPrank();
        assertEq(nft.ownerOf(TID), buyer);
        assertEq(wpc.balanceOf(seller), 2 ether); // full price, no fee
    }

    function testOnlyDesignatedBuyer() public {
        uint256 id = _create(address(0));
        vm.deal(stranger, 100 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("Not designated buyer"));
        ps.executePrivateSale{value: 2 ether}(id);
    }

    function testWrongValueReverts() public {
        uint256 id = _create(address(0));
        vm.prank(buyer);
        vm.expectRevert(bytes("Wrong native value"));
        ps.executePrivateSale{value: 1 ether}(id);
    }

    function testSellerCancel() public {
        uint256 id = _create(address(0));
        vm.prank(seller);
        ps.cancelPrivateSale(id);
        vm.prank(buyer);
        vm.expectRevert(bytes("Not active"));
        ps.executePrivateSale{value: 2 ether}(id);
    }

    function testCreateRequiresOwnership() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Not token owner"));
        ps.createPrivateSale(address(nft), TID, 2 ether, buyer, address(0));
    }
}
