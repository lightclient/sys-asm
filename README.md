# `7002asm`

This is a [`geas`][geas] implementation of the [EIP-7002][7002] system contract.

## Getting Started

To setup a dev environment capable of assembling, analyzing, and executing the
repository's assembly you will need to install [`foundry`][foundry] and
[`geas`][geas]. This can be accomplished by running:

```console
$ curl -L https://foundry.paradigm.xyz | bash
$ go install github.com/fjl/geas/cmd/geas@latest
```

## Building

To assemble `src/main.eas` you will need to invoke `geas`:

```console
$ geas src/main.eas
3373fffffffffffffffffffffffffffffffffffffffe146090573615156028575f545f5260205ff35b36603814156101215760115f54600182026001905f5b5f82111560595781019083028483029004916001019190603e565b90939004341061012157600154600101600155600354806003026004013381556001015f3581556001016020359055600101600355005b6003546002548082038060101160a4575060105b5f5b81811460dd5780604c02838201600302600401805490600101805490600101549160601b83528260140152906034015260010160a6565b910180921460ed579060025560f8565b90505f6002555f6003555b5f5460015460028282011161010f5750505f610115565b01600290035b5f555f600155604c025ff35b5f5ffd
```

## Testing

The tests can be executed using the `build-wrapper` script with the same arguments as [forge][forge]:

```console
$ ./build-wrapper test
[⠒] Compiling...
[⠒] Compiling 1 files with 0.8.14
[⠢] Solc 0.8.14 finished in 976.49ms
Compiler run successful!

Running 5 tests for test/Contract.t.sol:ContractTest
[PASS] testFakeExpo() (gas: 16063)
[PASS] testFee() (gas: 449136269)
[PASS] testInvalidRequest() (gas: 17248)
[PASS] testQueueReset() (gas: 7170334)
[PASS] testRequest() (gas: 152821)
Test result: ok. 5 passed; 0 failed; 0 skipped; finished in 870.90ms

Ran 1 test suites: 5 tests passed, 0 failed, 0 skipped (5 total tests)
```

[geas]: https://github.com/fjl/geas
[7002]: https://eips.ethereum.org/EIPS/eip-7002
[foundry]: https://getfoundry.sh/
[forge]: https://github.com/foundry-rs/foundry/blob/master/forge
