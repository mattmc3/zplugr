#!/usr/bin/env zsh
0=${(%):-%x}
@echo "=== ${0:t:r} ==="

# setup
BASEDIR=${0:A:h:h}
ANTIDOTE_HOME=$BASEDIR/tests/fakehome
source $BASEDIR/antidote.zsh

() {
  antidote path bar/foo &>/dev/null
  @test "'antidote path' fails on missing bundle" $? -ne 0
}

() {
  local expected actual
  expected="antidote: error: bar/foo does not exist in cloned paths"
  actual="$(antidote path bar/foo 2>&1)"
  @test "'antidote path' reports correct error string" $expected = $actual
}

() {
  antidote path foo/bar &>/dev/null
  @test "'antidote path' succeeds on found bundle" $? -eq 0
}

() {
  local expected actual
  actual=$(antidote path foo/bar 2>&1)
  expected=$ANTIDOTE_HOME/https-COLON--SLASH--SLASH-github.com-SLASH-foo-SLASH-bar
  @test "'antidote path' reports correct bundle path" $expected = $actual
}
