// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "geas-ffi/Geas.sol";
import "./Test.sol";

uint256 constant target_per_block = 2;
uint256 constant max_per_block = 16;
uint256 constant inhibitor = uint256(bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff));

contract WithdrawalsTest is Test {
  function setUp() public {
    vm.etch(addr, Geas.compile("src/withdrawals/main.eas"));
    vm.etch(fakeExpo, Geas.compile("src/common/fake_expo_test.eas"));
  }

  // testInvalidWithdrawal checks that common invalid withdrawal requests are rejected.
  function testInvalidWithdrawal() public {
    // pubkey too small
    (bool ret,) = addr.call{value: 1e18}(hex"1234");
    assertEq(ret, false);

    // pubkey 47 bytes
    (ret,) = addr.call{value: 1e18}(hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    assertEq(ret, false);

    // fee too small
    (ret,) = addr.call{value: 0}(hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    assertEq(ret, false);
  }

  // testWithdrawal verifies a single withdrawal request below the target request
  // count is accepted and read successfully.
  function testWithdrawal() public {
    bytes memory data    = hex"1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111110203040506070809";
    bytes memory exp_req = hex"1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111110908070605040302";

    vm.expectEmitAnonymous(false, false, false, false, true);
    assembly {
      let ptr := mload(0x40)
      mstore(ptr, shl(96, address()))
      mstore(add(ptr, 20), mload(add(data, 32)))
      mstore(add(ptr, 52), mload(add(data, 64)))
      log0(ptr, 76)
    }

    (bool ret,) = addr.call{value: 2}(data);
    assertEq(ret, true);
    assertStorage(count_slot, 1, "unexpected request count");
    assertExcess(0);

    bytes memory req = getRequests();
    assertEq(req.length, 76);
    assertEq(bytes20(req), bytes20(address(this)));            // check addr
    assertEq(toFixed(req, 20, 52), toFixed(exp_req, 0, 32));   // check pk1
    assertEq(toFixed(req, 52, 68), toFixed(exp_req, 32, 48));  // check pk2
    assertEq(toFixed(req, 68, 76), toFixed(exp_req, 48, 56));  // check amt
    assertStorage(count_slot, 0, "unexpected request count");
    assertExcess(0);
  }

  // testQueueReset verifies that after a period of time where there are more
  // request than can be read per block, the queue is eventually cleared and the
  // head and tails are reset to zero.
  function testQueueReset() public {
    // Add more withdrawal requests than the max per block (16) so that the
    // queue is not immediately emptied.
    for (uint256 i = 0; i < max_per_block+1; i++) {
      addRequest(address(uint160(i)), makeWithdrawal(i), 2);
    }
    assertStorage(count_slot, max_per_block+1, "unexpected request count");

    // Simulate syscall, check that max withdrawal requests per block are read.
    checkWithdrawals(0, max_per_block);
    assertExcess(15);

    // Add another batch of max withdrawal requests per block (16) so the next
    // read leaves a single withdrawal request in the queue.
    for (uint256 i = 17; i < 33; i++) {
      addRequest(address(uint160(i)), makeWithdrawal(i), 2);
    }
    assertStorage(count_slot, max_per_block, "unexpected request count");

    // Simulate syscall. Verify first that max per block are read. Then
    // verify only the single final requst is read.
    checkWithdrawals(16, max_per_block);
    assertExcess(29);
    checkWithdrawals(32, 1);
    assertExcess(27);

    // Now ensure the queue is empty and has reset to zero.
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");

    // Add five (5) more requests to check that new requests can be added after the queue
    // is reset.
    for (uint256 i = 33; i < 38; i++) {
      addRequest(address(uint160(i)), makeWithdrawal(i), 4);
    }
    assertStorage(count_slot, 5, "unexpected request count");

    // Simulate syscall, read only the max requests per block.
    checkWithdrawals(33, 5);
    assertExcess(30);
  }


  // testFee adds many requests, and verifies the fee decreases correctly until
  // it returns to 0.
  function testFee() public {
    uint256 idx = 0;
    uint256 count = max_per_block*64;

    // Add a bunch of requests.
    for (; idx < count; idx++) {
      addRequest(address(uint160(idx)), makeWithdrawal(idx), 1);
    }
    assertStorage(count_slot, count, "unexpected request count");
    checkWithdrawals(0, max_per_block);

    uint256 read = max_per_block;
    uint256 excess = count - target_per_block;

    // Attempt to add a withdrawal request with fee too low and a withdrawal
    // request with fee exactly correct. This should cause the excess requests
    // counter to decrease by 1 each iteration.
    for (uint256 i = 0; i < count; i++) {
      assertExcess(excess);

      uint256 fee = computeFee(excess);
      addFailedRequest(address(uint160(idx)), makeWithdrawal(idx), fee-1);
      addRequest(address(uint160(idx)), makeWithdrawal(idx), fee);

      uint256 expected = min(idx-read+1, max_per_block);
      checkWithdrawals(read, expected);

      if (excess != 0) {
        excess--;
      }
      read += expected;
      idx++;
    }

  }

  // testInhibitorReset verifies that after the first system call the excess
  // value is reset to 0.
  function testInhibitorReset() public {
    vm.store(addr, bytes32(0), bytes32(inhibitor));
    vm.prank(sysaddr);
    (bool ret, bytes memory data) = addr.call("");
    assertStorage(excess_slot, 0, "expected excess requests to be reset");

    vm.store(addr, bytes32(0), bytes32(inhibitor));
    addFailedRequest(address(uint160(0)), makeWithdrawal(0), inhibitor);

    vm.store(addr, bytes32(0), bytes32(inhibitor-1));
    vm.prank(sysaddr);
    (ret, data) = addr.call("");
    assertStorage(excess_slot, inhibitor-target_per_block-1, "didn't expect excess to be reset");
  }

  // --------------------------------------------------------------------------
  // helpers ------------------------------------------------------------------
  // --------------------------------------------------------------------------

  // addRequest will submit a request to the system contract with the given values.
  function addRequest(address from, bytes memory req, uint256 value) internal {
    // Load tail index before adding request.
    uint256 requests = load(count_slot);
    uint256 tail = load(queue_tail_slot);

    // Send request from address.
    vm.deal(from, value);
    vm.prank(from);
    (bool ret,) = addr.call{value: value}(req);
    assertEq(ret, true, "expected call to succeed");

    // Verify the queue data was updated correctly.
    assertStorage(count_slot, requests+1, "unexpected request count");
    assertStorage(queue_tail_slot, tail+1, "unexpected tail slot");

    // Verify the request was written to the queue.
    uint256 idx = queue_storage_offset+tail*3;
    assertStorage(idx, uint256(uint160(from)), "addr not written to queue");
    assertStorage(idx+1, toFixed(req, 0, 32), "pk[0:32] not written to queue");
    assertStorage(idx+2, toFixed(req, 32, 56), "pk2_am not written to queue");
  }

  // checkWithdrawals will simulate a system call to the system contract and verify
  // the expected withdrawal requests are returned.
  //
  // It assumes that addresses are stored as uint256(index) and pubkeys are
  // uint8(index), repeating.
  function checkWithdrawals(uint256 startIndex, uint256 count) internal returns (uint256) {
    bytes memory amountBuffer = new bytes(8);
    bytes memory requests = getRequests();
    assertEq(requests.length, count*76);

    for (uint256 i = 0; i < count; i++) {
      uint256 offset = i*76;
      uint256 wdIndex = startIndex + i;
      bytes memory wd = makeWithdrawal(wdIndex);

      // Check address, pubkey.
      assertEq(toFixed(requests, offset, offset+20) >> 96, uint256(wdIndex), "unexpected request address returned");
      assertEq(toFixed(requests, offset+20, offset+52), toFixed(wd, 0, 32), "unexpected request pk1 returned");
      assertEq(toFixed(requests, offset+52, offset+68), toFixed(wd, 32, 48), "unexpected request pk2 returned");

      // Check amount.
      for (uint j = 0; j < 8; j++) {
         amountBuffer[j] = requests[offset+68+j];
      }
      bytes memory wantAmount = hex"de852726f6fb9f2d";
      assertEq(amountBuffer, wantAmount, "unexpected request amount returned");
    }

    return count;
  }

  // makeWithdrawal constructs a withdrawal request with a base of x.
  function makeWithdrawal(uint256 x) internal pure returns (bytes memory) {
    bytes memory pk = new bytes(48);
    for (uint256 i = 0; i < 48; i++) {
      pk[i] = bytes1(uint8(x));
    }
    bytes memory amt = hex"2d9ffbf6262785de";
    bytes memory out = bytes.concat(pk, amt);
    require(out.length == 56);
    return out;
  }
}
