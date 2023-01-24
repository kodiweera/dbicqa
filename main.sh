# commandline
# bash main.sh *date* *dicom_qadata_folder_name*

# variables: $1- date, $2 - directory (i.e, qadata which contains dicom files)

# results is the output directory inside the qadata forlder

singularity run --cleanenv --bind data/ containers/fbirnqa-1.11.14.sif data/$1/$2 /data/$1/$2/results


python fbirnpdf/qapdf.py data/$1/$2/results/ $1

# --creating longitudinal plots for boldp2

var="boldp2"

if [[ "$2" == "$var" ]]

then
	python qaplots/createxls.py

	python qaplots/qaplots.py qaplots/ $1
else
	echo "Skip plots for now!"

fi

