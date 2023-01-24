Under Constructions!!!

# fmri-fbirnqa
In this repo, I'm going to make avalable the fbirn qa scripts (pipeline) and information about the docker/singulartiy container used to produce results shown in https://www.dartmouth.edu/dbic/research_infrastructure/qualityassurance.html


https://www.nitrc.org/projects/fbirn/


https://hub.docker.com/repository/docker/diffdocker/fbirnqa


You can create a singularity contaner using the docker image (recommended)



##Run the docker image

docker run fbirnqa:1.11.14 "input dir" "output dir"

##Create a singularity container

singularity build fbirnqa-1.11.14.sif docker://diffdocker/fbirnqa:1.11.14



##Run using the singularity container

singularity run --cleanenv fbirnqa.sif "input dir" "output dir"
You may have to bind the data directory.
