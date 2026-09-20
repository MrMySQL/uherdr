#!/bin/sh
# Verify the actual SSH invocation without contacting a host.
case " $* " in
  *' -l tester -p 2222 -- power.test LC_ALL=C /usr/bin/pmset -g batt'*) ;;
  *) exit 1 ;;
esac
printf "Login banner\nNow drawing from 'AC Power'\n -InternalBattery-0 (id=123)\t73%%; charging; 1:00 remaining present: true\n"
