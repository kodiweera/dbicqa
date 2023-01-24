
# variables: $1- date, $2 - directory (i.e, boldp2)

singularity run --cleanenv --bind /dartfs/rc/lab/D/DBIC/DBIC/QA:/dartfs/rc/lab/D/DBIC/DBIC/QA /dartfs/rc/lab/D/DBIC/DBIC/QA/containers/fbirnqa-1.11.14.sif /dartfs/rc/lab/D/DBIC/DBIC/QA/dbic-qa/32CH/$1/$2 /dartfs/rc/lab/D/DBIC/DBIC/QA/dbic-qa/32CH/$1/$2/result


python /dartfs/rc/lab/D/DBIC/DBIC/QA/fbirnpdf/qapdf.py /dartfs/rc/lab/D/DBIC/DBIC/QA/dbic-qa/32CH/$1/$2/result/ $1

# --creating longitudinal plots for boldp2

var="boldp2"

if [[ "$2" == "$var" ]]

then
	python /dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/createxls.py

	python /dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/qaplots.py /dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/ $1
else
	echo "Skip plots for now!"

fi

