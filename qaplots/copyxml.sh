#!/bin/bash
index=0
/bin/ls /dartfs/rc/lab/D/DBIC/DBIC/QA/dbic-qa/32CH/*/boldp2/result/summaryQA.xml \
| while read f; do
 fn="$(basename $f)"
 fn2="${fn//.xml}_${index}.xml"
 cp -a "$f" "/dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/summaryxml/$fn2"
 index=$(($index+1))
done

