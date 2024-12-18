// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "geas-ffi/Geas.sol";
import "./Test.sol";

uint256 constant target_per_block = 1;
uint256 constant max_per_block = 2;
uint256 constant inhibitor = uint256(bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff));

contract ConsolidationTest is Test {

  function setUp() public {
    vm.etch(addr, Geas.compile("src/consolidations/main.eas"));
    vm.etch(fakeExpo, Geas.compile("src/common/fake_expo_test.eas"));
  }

  // testInvalidRequest checks that common invalid requests are rejected.
  function testInvalidRequest() public {
    // pubkeys are too small
    (bool ret,) = addr.call{value: 1e18}(hex"1234");
    assertEq(ret, false);

    // pubkeys 95 bytes
    (ret,) = addr.call{value: 1e18}(hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    assertEq(ret, false);

    // fee too small
    (ret,) = addr.call{value: 0}(hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    assertEq(ret, false);
  }

  // testConsolidation verifies a single consolidation request below the target
  // request count is accepted and read successfully.
  function testConsolidation() public {
    bytes memory data = hex"111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222";

    vm.expectEmitAnonymous(false, false, false, false, true);
    assembly {
      let ptr := mload(0x40)
      mstore(ptr, shl(96, address()))
      mstore(add(ptr, 20), mload(add(data, 32)))
      mstore(add(ptr, 52), mload(add(data, 64)))
      mstore(add(ptr, 84), mload(add(data, 96)))
      log0(ptr, 116)
    }

    (bool ret,) = addr.call{value: 2}(data);
    assertEq(ret, true, "call failed");
    assertStorage(count_slot, 1, "unexpected request count");
    assertExcess(0);

    bytes memory req = getRequests();
    assertEq(req.length, 116);
    assertEq(toFixed(req, 20, 52), toFixed(data, 0, 32));
    assertEq(toFixed(req, 52, 84), toFixed(data, 32, 64));
    assertEq(toFixed(req, 84, 116), toFixed(data, 64, 96));
    assertStorage(count_slot, 0, "unexpected request count");
    assertExcess(0);
  }

  // testQueueReset verifies that after a period of time where there are more
  // request than can be read per block, the queue is eventually cleared and the
  // head and tails are reset to zero.
  function testQueueReset() public {
    // Add more requests than the max per block (2) so that the queue is not
    // immediately emptied.
    for (uint256 i = 0; i < max_per_block+1; i++) {
      addRequest(address(uint160(i)), makeConsolidation(i), 2);
    }
    assertStorage(count_slot, max_per_block+1, "unexpected request count");

    // Simulate syscall, check that max requests per block are read.
    checkConsolidations(0, max_per_block);
    assertExcess(2);

    // Add another batch of max requests per block (2) so the next read leaves a
    // single request in the queue.
    for (uint256 i = 3; i < 3 + max_per_block; i++) {
      addRequest(address(uint160(i)), makeConsolidation(i), 2);
    }
    assertStorage(count_slot, max_per_block, "unexpected request count");

    // Simulate syscall. Verify first that max per block are read. Then
    // verify only the single final request is read.
    checkConsolidations(2, max_per_block);
    assertExcess(3);
    checkConsolidations(4, 1);
    assertExcess(2);

    // Now ensure the queue is empty and has reset to zero.
    assertStorage(queue_head_slot, 0, "expected queue head reset");
    assertStorage(queue_tail_slot, 0, "expected queue tail reset");

    // Add five (5) more requests to check that new requests can be added after the queue
    // is reset.
    for (uint256 i = 5; i < 10; i++) {
      addRequest(address(uint160(i)), makeConsolidation(i), 4);
    }
    assertStorage(count_slot, 5, "unexpected request count");

    // Simulate syscall, read only the max requests per block.
    checkConsolidations(5, max_per_block);
    assertExcess(6);
  }

  // testFee adds many requests, and verifies the fee decreases correctly until
  // it returns to 0.
  function testFee() public {
    uint256 idx = 0;
    uint256 count = max_per_block*64;

    // Add a bunch of requests.
    for (; idx < count; idx++) {
      addRequest(address(uint160(idx)), makeConsolidation(idx), 1);
    }
    assertStorage(count_slot, count, "unexpected request count");
    checkConsolidations(0, max_per_block);

    uint256 read = max_per_block;
    uint256 excess = count - target_per_block;

    // Attempt to add an invalid request with fee too low or a valid request.
    // This should cause the excess requests counter to either decrease by 1 
    // or remain the same each iteration.
    for (uint256 i = 0; i < count; i++) {
      assertExcess(excess);
      
      uint256 fee = computeFee(excess);
      bool success = (i % 2 == 0);
      if (success) {
        addRequest(address(uint160(idx)), makeConsolidation(idx), fee);
        // Bump index when a new request is created
        idx++;
      } else {
        addFailedRequest(address(uint160(idx)), makeConsolidation(idx), fee-1);
      }
      
      uint256 queue_size = idx - read;
      uint256 expected = min(queue_size, max_per_block);
      checkConsolidations(read, expected);

      if (excess > 0 && !success) {
        excess--;
      }
      read += expected;
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
    addFailedRequest(address(uint160(0)), makeConsolidation(0), inhibitor);

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
    uint256 idx = queue_storage_offset+tail*4;
    assertStorage(idx, uint256(uint160(from)), "addr not written to queue");
    assertStorage(idx+1, toFixed(req, 0, 32), "source[0:32] not written to queue");
    assertStorage(idx+2, toFixed(req, 32, 64), "source[32:48] ++ target[0:16] not written to queue");
    assertStorage(idx+3, toFixed(req, 64, 96), "target[16:48] not written to queue");
  }

  // checkConsolidations will simulate a system call to the system contract and
  // verify the expected consolidation requests are returned.
  //
  // It assumes that addresses are stored as uint256(index) and pubkeys are
  // uint8(index), repeating.
  function checkConsolidations(uint256 startIndex, uint256 count) internal returns (uint256) {
    bytes memory requests = getRequests();
    assertEq(requests.length, count*116);
    for (uint256 i = 0; i < count; i++) {
      uint256 offset = i*116;
      assertEq(toFixed(requests, offset, offset+20) >> 96, uint256(startIndex+i), "unexpected request address returned");
      assertEq(toFixed(requests, offset+20, offset+52), toFixed(makeConsolidation(startIndex+i), 0, 32), "unexpected source[0:32] returned");
      assertEq(toFixed(requests, offset+52, offset+84), toFixed(makeConsolidation(startIndex+i), 32, 64), "unexpected source[32:48] ++ target[0:16] returned");
      assertEq(toFixed(requests, offset+84, offset+116), toFixed(makeConsolidation(startIndex+i), 64, 96), "unexpected target[16:48] returned");
    }
    return count;
  }

  // makeWithdrawal constructs a withdrawal request with a base of x.
  function makeConsolidation(uint256 x) internal pure returns (bytes memory) {
    bytes memory out = new bytes(96);
    // source
    for (uint256 i = 0; i < 48; i++) {
      out[i] = bytes1(uint8(x));
    }
    // target
    for (uint256 i = 0; i < 48; i++) {
      out[48 + i] = bytes1(uint8(x+1));
    }
    return out;
  }
}
