// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "geas-ffi/Geas.sol";
import "./Test.sol";

contract FakeExpoTest is Test {
  function setUp() public {
    vm.etch(fakeExpo, Geas.compile("src/common/fake_expo_test.eas"));
  }

  // testFakeExpo calls the fake exponentiation logic with specific values.
  function testFakeExpo() public {
    assertEq(callFakeExpo(1, 100, 17), 357);
  }
}
