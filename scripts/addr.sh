#!/bin/bash

if ! command -v go &> /dev/null
then
  echo "Go is not installed. Please install Go and try again."
  exit 1
fi

if ! command -v nick &> /dev/null
then
  echo "nick could not be found, installing..."
  go install github.com/lightclient/nick@latest
  if [ $? -ne 0 ]; then
    echo "Failed to install nick."
    exit 1
  fi
fi

if ! command -v geas &> /dev/null
then
  echo "geas could not be found, installing..."
  go install github.com/fjl/geas@latest
  if [ $? -ne 0 ]; then
    echo "Failed to install geas."
    exit 1
  fi
fi

default_score=5
score=${2:-$default_score}

case $1 in
  beaconroot|b|4788)
    echo "searching for beacon root deployment data "
    nick search --score=$score --initcode="0x$(geas src/beacon_root/ctor.eas)" --prefix=0xbeac02 --suffix=0x0000
    ;;
  withdrawals|wxs|7002)
    echo "searching for withdrawals deployment data "
    nick search --score=$score --initcode="0x$(geas src/withdrawals/ctor.eas)" --prefix=0x0000 --suffix=0xaaaa
    ;;
  consolidations|cxs|7251)
    echo "searching for consolidations deployment data "
    nick search --score=$score --initcode="0x$(geas src/consolidations/ctor.eas)" --prefix=0x0000 --suffix=0xbbbb
    ;;
  exechash|e|2935)
    echo "searching for execution hash deployment data "
    nick search --score=$score --initcode="0x$(geas src/execution_hash/ctor.eas)" --prefix=0x0000 --suffix=0xcccc
    ;;
  *)
    echo "Invalid option. Usage: $0 {withdrawals|consolidations}"
    ;;
esac
