#!/usr/bin/env bash
# pim library: the tart backend (macOS guests). Sourced by ~/.local/bin/pim; functions only.

_tart_todo() { die "the tart backend is not implemented yet"; }
tart_build()    { _tart_todo; }
tart_up()       { _tart_todo; }
tart_running()  { return 1; }
tart_stop()     { :; }
tart_shell()    { _tart_todo; }
tart_verify()   { _tart_todo; }
tart_snapshot() { _tart_todo; }
tart_reset()    { _tart_todo; }
tart_rm()       { :; }
