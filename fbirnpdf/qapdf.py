# Chandana Kodiweera, DBIC

import xml.etree.ElementTree as et
import pandas as pd
from bs4 import BeautifulSoup as bs
from fpdf import FPDF
from pandas.plotting import table 
import matplotlib.pyplot as plt
from os import path
import sys

BASE = sys.argv[1]
DATE = sys.argv[2]
#outname = sys.argv[3]
outname = DATE + ".pdf"

content = []
# Read the XML file
with open(path.join(BASE + "summaryQA.xml"), "r") as file:
    # Read each line in the file, readlines() returns a list of lines
    content = file.readlines()
    # Combine the lines in the list into a string
    content = "".join(content)
    soup = bs(content, "lxml")

#-------Prepearing the table-----------

mean = soup.find("observation", {"name":"mean"}).text
SNR = soup.find("observation", {"name":"SNR"}).text
SFNR = soup.find("observation", {"name":"SFNR"}).text
PercentFluc = soup.find("observation", {"name":"percentFluc"}).text
drift = soup.find("observation", {"name":"drift"}).text
rdc = soup.find("observation", {"name":"rdc"}).text
ghost = soup.find("observation", {"name":"meanGhost"}).text
std = soup.find("observation", {"name":"std"}).text

values = [mean, SNR, SFNR, PercentFluc, drift, rdc, ghost, std]
values


col1 = ["mean signal (mean)", "Signal to Noise Ratio (SNR)", "Signal to Fluctuation Ratio (SFNR)", "Percent Fluctuation", "Drift", "Radius of Decorrelation (RDC)", "Mean Ghost Percentage", "Standard Deviation (std)"]


titles = ["Measurments", "Value"]


df = pd.DataFrame(columns=titles)
df["Measurments"] = col1
df["Value"] = values

pd.set_option('max_colwidth', 50)

df.style.set_properties(**{'text-align': 'left'})
df.reset_index(drop=True, inplace=True)


fig, ax = plt.subplots(1, 1, figsize=(6,2))
ax.xaxis.set_visible(False)  # hide the x axis
ax.yaxis.set_visible(False)  # hide the y axis

ax.table(cellText=df.values, colLabels=df.keys(), loc='center')


fig.dpi = 100
plt.savefig(path.join(BASE + 'values.png'))


#--------------------------------

pdf = FPDF()
pdf.add_page()

pdf.set_font("Arial", size = 15)


pdf.cell(200, 10, txt = "Dartmouth Brain Imaging Center (DBIC)",
         ln = 1, align = 'C')

pdf.cell(200, 10, txt = "QA Report 32 CH ", 
         ln = 2, align = 'C')
         
pdf.cell(200, 10, txt = DATE, 
         ln = 2, align = 'C')
         
#-------------------TABLE---------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C')          
pdf.cell(200, 8, txt = "Measurements", 
         ln = 3, align = 'C')
values = path.join(BASE, "values.png")
pdf.image(values, x = None, y = None, w = 200, h = 80)


#----------------------Signal-------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
pdf.cell(200, 8, txt = "Signal ", 
         ln = 4, align = 'C')
signal = path.join(BASE, "qa_signal.png")

pdf.image(signal, x = 30, y = None, w = 150, h = 80)


#------------------Spectrum------------------------

pdf.cell(200, 30, txt = "", 
         ln = 5, align = 'C')       
pdf.cell(200, 8, txt = "Frequence Spectrum", 
         ln = 5, align = 'C')
         
spectrum = path.join(BASE, "qa_spectrum.png")

pdf.image(spectrum, x = 30, y = None, w = 150, h = 80)



#------------------RDC------------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Raduis of Decorrelation", 
         ln = 6, align = 'C')
         
rdc = path.join(BASE, "qa_relstd.png")

pdf.image(rdc, x = 30, y = None, w = 150, h = 80)

#------------------Smoothness X------------------------
pdf.cell(200, 50, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Smoothness -X ", 
         ln = 6, align = 'C')
         
fwhmx = path.join(BASE, "qa_fwhmx.png")

pdf.image(fwhmx, x = 30, y = None, w = 150, h = 80)


#------------------Smoothness Y------------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Smoothness -Y ", 
         ln = 6, align = 'C')
         
fwhmy = path.join(BASE, "qa_fwhmy.png")

pdf.image(fwhmy, x = 30, y = None, w = 150, h = 80)

#------------------Smoothness Z------------------------
pdf.cell(200, 30, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Smoothness -Z ", 
         ln = 6, align = 'C')
         
fwhmz = path.join(BASE, "qa_fwhmz.png")

pdf.image(fwhmz, x = 30, y = None, w = 150, h = 80)


#------------------Center of Mass X------------------------
pdf.cell(200, 30, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Center of Mass -X ", 
         ln = 6, align = 'C')
         
cmassx = path.join(BASE, "qa_cmassx.png")

pdf.image(cmassx, x = 30, y = None, w = 150, h = 80)


#------------------Center of Mass Y------------------------
pdf.cell(200, 40, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Center of Mass -Y ", 
         ln = 6, align = 'C')
         
cmassy = path.join(BASE, "qa_cmassy.png")

pdf.image(cmassy, x = 30, y = None, w = 150, h = 80)

#------------------Center of Mass Z------------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Center of Mass -Z ", 
         ln = 6, align = 'C')
         
cmassz = path.join(BASE, "qa_cmassz.png")

pdf.image(cmassz, x = 30, y = None, w = 150, h = 80)


#------------------Ghost------------------------
pdf.cell(200, 30, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Ghost", 
         ln = 6, align = 'C')
         
ghost = path.join(BASE, "qa_ghost.png")

pdf.image(ghost, x = 30, y = None, w = 150, h = 80)


#------------------Odd-Even Difference Image------------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Odd-Even Difference Image ", 
         ln = 6, align = 'C')
         
nave = path.join(BASE, "result_nave.jpg")

pdf.image(nave, x = 60, y = None, w = 100, h = 100)


#------------------Mean Image------------------------
pdf.cell(200, 50, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Mean Image ", 
         ln = 6, align = 'C')
         
ave = path.join(BASE, "result_ave.jpg")

pdf.image(ave, x = 60, y = None, w = 100, h = 100)


#------------------Standard Deviation Image------------------------
pdf.cell(200, 20, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "Standard Deviation Image ", 
         ln = 6, align = 'C')
         
sd = path.join(BASE, "result_sd.jpg")

pdf.image(sd, x = 60, y = None, w = 100, h = 100)


#------------------SFNR Image------------------------
pdf.cell(200, 40, txt = "", 
         ln = 5, align = 'C') 
        
pdf.cell(200, 8, txt = "SFNR Image ", 
         ln = 6, align = 'C')
         
sfnr = path.join(BASE, "result_sfnr.jpg")

pdf.image(sfnr, x = 60, y = None, w = 100, h = 100)






pdf.output(path.join(BASE, outname))
  
