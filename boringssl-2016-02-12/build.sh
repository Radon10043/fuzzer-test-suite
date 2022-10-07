#!/bin/bash
# Copyright 2016 Google Inc. All Rights Reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
. $(dirname $0)/../custom-build.sh $1 $2
. $(dirname $0)/../common.sh

build_lib() {
  rm -rf BUILD
  cp -rf SRC BUILD
  (cd BUILD && cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$CFLAGS -Wno-deprecated-declarations" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CXX_FLAGS="$CXXFLAGS -Wno-error=main" && make -j $JOBS)
}

build_lib_aflgo() {
  rm -rf BUILD
  cp -rf SRC BUILD

  # AFLGo files
  rm -rf temp
  mkdir temp
  export TMP_DIR=$PWD/temp
  export SUBJECT=$PWD/BUILD
  export CC=$AFLGO_SRC/afl-clang-fast
  export CXX=$AFLGO_SRC/afl-clang-fast++
  export CFLAGS="-targets=$TMP_DIR/BBtargets.txt -outdir=$TMP_DIR -flto -fuse-ld=gold -Wl,-plugin-opt=save-temps"
  export CXXFLAGS="$CFLAGS"
  echo "asn1_lib.c:459" >$TMP_DIR/BBtargets.txt

  # preprocess
  (cd BUILD && cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$CFLAGS -Wno-deprecated-declarations" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CXX_FLAGS="$CXXFLAGS -Wno-error=main" && make -j $JOBS)
  cat $TMP_DIR/BBnames.txt | rev | cut -d: -f2- | rev | sort | uniq >$TMP_DIR/BBnames2.txt && mv $TMP_DIR/BBnames2.txt $TMP_DIR/BBnames.txt
  cat $TMP_DIR/BBcalls.txt | sort | uniq >$TMP_DIR/BBcalls2.txt && mv $TMP_DIR/BBcalls2.txt $TMP_DIR/BBcalls.txt

  $AFLGO_SRC/scripts/genDistance.sh $SUBJECT $TMP_DIR
  export CFLAGS="-distance=$TMP_DIR/distance.cfg.txt"
  export CXXFLAGS="$CFLAGS"

  # instrument
  (cd BUILD && cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$CFLAGS -Wno-deprecated-declarations" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CXX_FLAGS="$CXXFLAGS -Wno-error=main" && make -j $JOBS)

  # unset variables
  unset CC CXX CFLAGS CXXFLAGS
}

fuzz() {
  export AFLGO=/home/radon/Documents/fuzzing/fuzzers/aflgo
  $AFLGO/afl-fuzz -i seeds -o out -m none -z exp -c 45m -d ./boringssl-2016-02-12-aflgo @@
}

get_git_revision https://github.com/google/boringssl.git  894a47df2423f0d2b6be57e6d90f2bea88213382 SRC

if [[ $FUZZING_ENGINE == "aflgo" ]]; then
  build_lib_aflgo
else
  build_lib
fi

. $(dirname $0)/../common.sh
build_fuzzer

if [[ ! -d seeds ]]; then
  mkdir seeds
  cp BUILD/fuzz/privkey_corpus/* seeds/
fi

if [[ $FUZZING_ENGINE == "hooks" ]]; then
  # Link ASan runtime so we can hook memcmp et al.
  LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE -fsanitize=address"
fi
set -x
$CXX $CXXFLAGS -I BUILD/include BUILD/fuzz/privkey.cc ./BUILD/ssl/libssl.a ./BUILD/crypto/libcrypto.a -lpthread $LIB_FUZZING_ENGINE -o $EXECUTABLE_NAME_BASE
