#!/bin/sh
# Call with file in current directory as argument

BXH=/home/fbirnqa/fbirnqa/bxh_xcede/bin

if [ $# -eq 2 ] 
then
    echo "Processing $1 through birn pipeline" 
else
    echo "Need two arguments: source and outdir name"
    exit 1
fi


#Model:
#dicom2bxh --xcede *.dcm WRAPPED.xml
#fmriqa_phantomqa.pl WRAPPED.xml OUTPUTQADIR

$BXH/dicom2bxh --xcede $1/* ${2}.xml
# insert space after comment characters
sed -e 's/<!--/<!-- /' ${2}.xml > tempscan.xml
/bin/rm -f ${2}.xml
/bin/mv tempscan.xml ${2}.xml
$BXH/fmriqa_phantomqa.pl --roisize 21 ${2}.xml $2

# compress but don't delete originals automatically
#/bin/tar cvf ${1}.tar ${1}
#/usr/bin/bzip2 ${1}.tar

exit 0

