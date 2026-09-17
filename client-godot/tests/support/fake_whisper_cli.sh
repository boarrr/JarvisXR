#!/bin/sh
output_base=""
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-of" ]; then
		output_base="$2"
		shift 2
		continue
	fi
	shift
done
if [ -z "$output_base" ]; then
	exit 2
fi
printf '%s\n' 'Private local speech transcript' > "${output_base}.txt"
