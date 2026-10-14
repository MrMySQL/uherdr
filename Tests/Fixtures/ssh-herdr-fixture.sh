#!/bin/sh
# Plays an SSH server: prints a login banner, then runs the remote command in a
# shell whose HOME is the test's and whose PATH has no herdr.
for command; do :; done
printf 'Login banner\n'
HOME="$UHERDR_TEST_HOME" PATH=/usr/bin:/bin exec /bin/sh -c "$command"
