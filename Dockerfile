# Script Author : Chandana Kodiweera
# Use Ubuntu 20.04 
FROM ubuntu:focal-20210921

USER root

ENV TZ=US
#RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV DEBIAN_FRONTEND noninteractive

# Prepare environment
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    		    tcsh xfonts-base libssl-dev \
    		    lsb-core \
    		    software-properties-common \
                    curl \
                    bzip2 \
                    ca-certificates \
                    xvfb \
                    build-essential \
                    autoconf \
                    libtool \
                    pkg-config \
                    graphviz \
                    libglw-dev \
                    libglu1-mesa \  
                    python-is-python3                 \
                    python3-matplotlib python3-numpy  \
                    gsl-bin netpbm gnome-tweak-tool   \
                    libjpeg62 xvfb xterm vim curl     \
                    gedit evince eog                  \
                    libglu1-mesa-dev libglw1-mesa     \
                    libxm4 build-essential            \
                    libcurl4-openssl-dev libxml2-dev  \
                    libgfortran-8-dev libgomp1        \
                    gnome-terminal nautilus           \
                    gnome-icon-theme-symbolic         \
                    firefox xfonts-100dpi             \
                    r-base-dev                        \
                    libgdal-dev libopenblas-dev       \
                    libnode-dev libudunits2-dev       \
                    libgfortran4                     \
                    wget \    
                    git && \
    add-apt-repository universe && \
    add-apt-repository -y "ppa:marutter/rrutter4.0" && \
    add-apt-repository -y "ppa:c2d4u.team/c2d4u4.0+" && \
    ln -s /usr/lib/x86_64-linux-gnu/libgsl.so.23 /usr/lib/x86_64-linux-gnu/libgsl.so.19 && \ 
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
    
RUN useradd -m -s /bin/bash -G users fbirnqa
WORKDIR /home/fbirnqa
ENV HOME="/home/fbirnqa"

ENV PATH="/home/fbirnqa/abin:$PATH" \
    AFNI_PLUGINPATH="/home/fbirnqa/abin"
    
RUN ldconfig && \
    echo "Downloading AFNI ..." && \
    mkdir -p /home/fbirnqa/abin && \
    cd &&\
    curl -O https://afni.nimh.nih.gov/pub/dist/bin/misc/@update.afni.binaries && \
    tcsh @update.afni.binaries -package linux_ubuntu_16_64 -do_extras
   
                
# Create a shared $HOME directory
#RUN useradd -m -s /bin/bash -G users fbirnqa
#WORKDIR /home/fbirnqa
#ENV HOME="/home/fbirnqa"
 
# Installing fbirnqa
COPY fbirnqa /home/fbirnqa/fbirnqa

ENTRYPOINT ["/home/fbirnqa/fbirnqa/fbirnqa.sh"] 


ARG BUILD_DATE

LABEL org.label-schema.build-date=$BUILD_DATE \
      org.label-schema.name="fbirnqa" \
      org.label-schema.description="MRI fbrin-qa By G. H. Glover, Stanford University and FBIRN" \
      org.label-schema.url="https://www.nitrc.org/projects/fbirn/" 
      
     
