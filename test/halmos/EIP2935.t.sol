// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

/*
 * Functional correctness verification for the system contract bytecode in https://eips.ethereum.org/EIPS/eip-2935
 *
 * This test verifies that the bytecode implementation conforms to the specifications in EIP-2935.
 * By leveraging symbolic execution, the test exhaustively explores all possible execution behaviors, providing higher confidence in the implementation correctness.
 */

/*
 *  EIP-2935 behavior overview:
 *
 *  At the beginning of processing a block where `block.number == 8192*k + i`,
 *  the `set` operation updates the storage as follows, where `calldata[0:32] == blockhash(8192*k + i-1)`:
 *
 *      Slot    Data                                        New data after `set` operation
 *
 *        0     blockhash(8192* k    +  0   )               <unchanged>
 *        1     blockhash(8192* k    +  1   )               <unchanged>
 *       ...    ...                                         ...
 *       i-2    blockhash(8192* k    + i-2  )               <unchanged>
 *       i-1    blockhash(8192*(k-1) + i-1  )   == set ==>  blockhash(8192*k + i-1)
 *        i     blockhash(8192*(k-1) +  i   )               <unchanged>
 *       ...    ...                                         ...
 *      8190    blockhash(8192*(k-1) + 8190 )               <unchanged>
 *      8191    blockhash(8192*(k-1) + 8191 )               <unchanged>
 *      8192    0                                           <unchanged>
 *       ...    ...                                         ...
 *   2^256-1    0                                           <unchanged>
 *
 *  Then, during the processing of the block at `8192*k + i`,
 *  the `get` operation reads the storage at the slot `calldata[0:32] % 8192`,
 *  as long as `calldata[0:32]` falls within the range `[8192*(k-1) + i, 8192*k + i-1]` (inclusive).
 *  Otherwise, it returns 0.
 */

/*
 *  Edge cases:
 *
 *  When `block.number == 0`:
 *  - The `set` operation updates slot 8191 with the given `calldata[0:32]` value.
 *    If this value is non-zero, it could lead to storage corruption.
 *  - The `get` operation reads from slot `calldata[0:32] % 8192`, rather than immediately returning 0.
 *    If the storage is corrupted, this operation may retrieve corrupted data.
 *  - While this is not relevant to the Ethereum chain, it could pose issues for other EVM chains upon creation.
 */

/// @custom:halmos --storage-layout generic --panic-error-codes *
contract EIP2935Test is SymTest, Test {
    // constants defined in EIP-2935
    address constant HISTORY_STORAGE_ADDRESS = address(0x0AAE40965E6800cD9b1f4b05ff21581047E3F91e);
    address constant SYSTEM_ADDRESS = address(0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);

    uint constant HISTORY_SERVE_WINDOW = 8192;

    // variables for specifying correctness properties
    struct State {
        uint256 balance;
        uint256 anySlotValue;
    }
    State internal initState;
    uint256 internal anySlot; // a universally quantified variable representing any storage slot

    function setUp() public {
        // set the bytecode given in https://eips.ethereum.org/EIPS/eip-2935
        vm.etch(HISTORY_STORAGE_ADDRESS, hex"3373fffffffffffffffffffffffffffffffffffffffe1460575767ffffffffffffffff5f3511605357600143035f3511604b575f35612000014311604b57611fff5f3516545f5260205ff35b5f5f5260205ff35b5f5ffd5b5f35611fff60014303165500");

        // set symbolic storage and balance
        svm.enableSymbolicStorage(HISTORY_STORAGE_ADDRESS);
        vm.deal(HISTORY_STORAGE_ADDRESS, svm.createUint(96, "HISTORY_STORAGE_ADDRESS.balance"));

        // set symbolic block info
        _setUpBlock();

        // create a symbol for an arbitrary storage slot number
        anySlot = svm.createUint256("anySlot");

        // record initial state
        initState = _getState();

        // TODO: what's the expected behavior when block.number == 0?
        vm.assume(block.number > 0);
    }

    /// @custom:halmos --array-lengths data={0,1,2,32,1024}
    function check_operation(address caller, uint value, bytes memory data) public {
        // set symbolic balance for caller
        uint256 callerBalance = svm.createUint(96, "caller.balance");
        vm.deal(caller, callerBalance);

        // call HISTORY_STORAGE_ADDRESS
        vm.prank(caller);
        (bool success, bytes memory retdata) = HISTORY_STORAGE_ADDRESS.call{value: value}(data);

        // record the updated state
        State memory newState = _getState();

        // get() operation
        if (caller != SYSTEM_ADDRESS) {
            uint input = uint(bytes32(data)); // implicit zero-padding if data.length < 32
            if (input < 2**64) {
                assertTrue(success);
                // valid input range: [block.number - HISTORY_SERVE_WINDOW, block.number - 1] (inclusive)
                if (block.number <= input + HISTORY_SERVE_WINDOW && input + 1 <= block.number) {
                    assertEq(bytes32(retdata), vm.load(HISTORY_STORAGE_ADDRESS, bytes32(input % HISTORY_SERVE_WINDOW)));
                } else {
                    // ensure return 0 for any input outside the valid range
                    assertEq(bytes32(retdata), 0);
                }
            } else {
                // ensure revert if calldata is bigger than 2^64-1
                assertFalse(success);
            }

            // ensure no storage updates
            assertEq(newState.anySlotValue, initState.anySlotValue);

        // set() operation
        } else {
            // ensure set() operation never reverts
            assertTrue(success);

            // ensure the storage value at `block.number-1 % HISTORY_SERVE_WINDOW` is set to calldata[0:32]
            bytes32 input = bytes32(data); // implicit zero-padding if data.length < 32
            assertEq(input, vm.load(HISTORY_STORAGE_ADDRESS, bytes32((block.number - 1) % HISTORY_SERVE_WINDOW)));

            // ensure no storage updates other than the set slot
            if (anySlot != (block.number - 1) % HISTORY_SERVE_WINDOW) {
                assertEq(newState.anySlotValue, initState.anySlotValue);
            }
        }

        // ensure balance updates
        if (success) {
            _check_balance_update(newState, value, caller, callerBalance);
        }
    }

    function _check_balance_update(State memory newState, uint256 value, address caller, uint256 callerBalance) internal view {
        if (caller != HISTORY_STORAGE_ADDRESS) {
            assertEq(newState.balance, initState.balance + value);
            assertEq(caller.balance, callerBalance - value);
        } else {
            // caller == HISTORY_STORAGE_ADDRESS
            // self transfer, no balance change
            assertEq(caller.balance, callerBalance);
            // new balance set earlier by vm.deal(caller, callerBalance)
            assertEq(newState.balance, callerBalance);
        }
    }

    function _setUpBlock() internal {
        vm.fee(svm.createUint256("block.basefee"));
        vm.chainId(svm.createUint256("block.chainid"));
        vm.coinbase(svm.createAddress("block.coinbase"));
        vm.difficulty(svm.createUint256("block.difficulty"));
        vm.warp(svm.createUint256("block.timestamp"));
        vm.roll(svm.createUint256("block.number"));
    }

    function _getState() internal view returns (State memory) {
        uint256 balance = HISTORY_STORAGE_ADDRESS.balance;
        uint256 anySlotValue = uint256(vm.load(HISTORY_STORAGE_ADDRESS, bytes32(anySlot)));
        return State(balance, anySlotValue);
    }
}
