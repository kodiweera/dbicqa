import matplotlib
from matplotlib import pyplot as plt
import matplotlib.dates as mdates
import datetime as DT
import sys
from os import path


import numpy as np
import pandas as pd
matplotlib.style.use('ggplot')
#%matplotlib inline

frame = pd.read_excel('/dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/boldp2_summary.xls')
frame_short = frame.sort_values(by='scandate')
np_array = frame_short.to_numpy()

BASE = sys.argv[1]
DATE = sys.argv[2]
# SFNR-------------




x1 = np.array([np.datetime64(i) for i in np_array[:251,0]])
x1 = x1.astype(DT.datetime)
y1 = np_array[:251,2]
x2 = np.array([np.datetime64(i) for i in np_array[251:268,0]])
x2 = x2.astype(DT.datetime)
y2 = np_array[251:268,2]
x3 = np.array([np.datetime64(i) for i in np_array[268:282,0]])
x3 = x3.astype(DT.datetime)
y3 = np_array[268:282,2]
x4 = np.array([np.datetime64(i) for i in np_array[282:,0]])
x4 = x4.astype(DT.datetime)
y4 = np_array[282:,2]

fig1 = plt.figure(figsize=(3,2),dpi=150)
ax1 = fig1.add_axes([0,0,1,1])

ax1.plot(x1,y1,'mo', label="E11C", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x2,y2,'ro', label="E11E", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x3,y3,'yo', label="New body and gradient coils", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x4,y4,'bo', label="New body coil", markeredgecolor='m',markersize=5,markeredgewidth=1)
# Major ticks every 6 months.
fmt_month = mdates.MonthLocator(interval=6)
ax1.xaxis.set_major_locator(fmt_month)

# Minor ticks every month.
#fmt_month = mdates.MonthLocator()
#ax1.xaxis.set_minor_locator(fmt_month)

# Text in the x axis will be displayed in 'YYYY-mm' format.
ax1.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m'))

fig1.autofmt_xdate()

ax1.set_title("Signal-to-Fluctuation-Noise Ratio", fontsize=10)
#ax1.set_xlabel("Date")
ax1.set_ylabel("SFNR", fontsize=10)
ax1.legend(loc=0)
ax1.set_ylim([0,350])
sfnr = path.join(BASE + "SFNR-32CH-" + DATE + ".jpg") 
fig1.savefig(sfnr, bbox_inches='tight')


# SNR-----------------------

# x1 = np.array([np.datetime64(i) for i in np_array[:251,0]])
x1 = x1.astype(DT.datetime)
y1 = np_array[:251,1]
x2 = np.array([np.datetime64(i) for i in np_array[251:268,0]])
x2 = x2.astype(DT.datetime)
y2 = np_array[251:268,1]
x3 = np.array([np.datetime64(i) for i in np_array[268:282,0]])
x3 = x3.astype(DT.datetime)
y3 = np_array[268:282,1]
x4 = np.array([np.datetime64(i) for i in np_array[282:,0]])
x4 = x4.astype(DT.datetime)
y4 = np_array[282:,1]

fig1 = plt.figure(figsize=(3,2),dpi=150)
ax1 = fig1.add_axes([0,0,1,1])

ax1.plot(x1,y1,'mo', label="E11C", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x2,y2,'ro', label="E11E", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x3,y3,'yo', label="New body and gradient coils", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x4,y4,'bo', label="New body coil", markeredgecolor='m',markersize=5,markeredgewidth=1)

# Major ticks every 6 months.
fmt_month = mdates.MonthLocator(interval=6)
ax1.xaxis.set_major_locator(fmt_month)

# Minor ticks every month.
#fmt_month = mdates.MonthLocator()
#ax1.xaxis.set_minor_locator(fmt_month)

# Text in the x axis will be displayed in 'YYYY-mm' format.
ax1.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m'))

fig1.autofmt_xdate()

ax1.set_title("Signal-to-Noise Ratio", fontsize=10)
#ax1.set_xlabel("Date")
ax1.set_ylabel("SNR",fontsize=10)
ax1.legend(loc=0)
ax1.set_ylim([0,350])
snr = path.join(BASE + "SNR-32CH-" + DATE + ".jpg")
fig1.savefig(snr, bbox_inches='tight')


# Gohst ------------------

x1 = np.array([np.datetime64(i) for i in np_array[:251,0]])
x1 = x1.astype(DT.datetime)
y1 = np_array[:251,7]
x2 = np.array([np.datetime64(i) for i in np_array[251:268,0]])
x2 = x2.astype(DT.datetime)
y2 = np_array[251:268,7]
x3 = np.array([np.datetime64(i) for i in np_array[268:282,0]])
x3 = x3.astype(DT.datetime)
y3 = np_array[268:282,7]
x4 = np.array([np.datetime64(i) for i in np_array[282:,0]])
x4 = x4.astype(DT.datetime)
y4 = np_array[282:,7]

fig1 = plt.figure(figsize=(3,2),dpi=150)
ax1 = fig1.add_axes([0,0,1,1])

ax1.plot(x1,y1,'mo', label="E11C", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x2,y2,'ro', label="E11E", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x3,y3,'yo', label="New body and gradient coils", markeredgecolor='k',markersize=5,markeredgewidth=1)
ax1.plot(x4,y4,'bo', label="New body coil", markeredgecolor='m',markersize=5,markeredgewidth=1)
# Major ticks every 6 months.
fmt_month = mdates.MonthLocator(interval=6)
ax1.xaxis.set_major_locator(fmt_month)

# Minor ticks every month.
#fmt_month = mdates.MonthLocator()
#ax1.xaxis.set_minor_locator(fmt_month)

# Text in the x axis will be displayed in 'YYYY-mm' format.
ax1.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m'))

fig1.autofmt_xdate()

ax1.set_title("Mean Ghost Percentage", fontsize=10)
#ax1.set_xlabel("Date")
ax1.set_ylabel("Ghost %", fontsize=10)
ax1.legend(loc=0)
ax1.set_ylim([0,4])
ghost = path.join(BASE + "Ghost-32CH-" + DATE + ".jpg")
fig1.savefig(ghost, bbox_inches='tight')

