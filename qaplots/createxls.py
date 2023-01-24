import os
from lxml import etree
import os, sys
import pandas as pd


os.system('bash /dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/copyxml.sh') #copy summaryQA.xml files


data = []
topdir = '/dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/summaryxml'
for filename in os.listdir(topdir):
    try:
        e = etree.parse(os.path.join(topdir, filename)).getroot()
        print("Loaded %s" % filename)
    except:
        print("Failed to load %s" % filename)
        continue
    data.append({
        k: t(e.xpath(
            "//a:observation[@name='%s']" % k,
            namespaces={'a': 'http://www.xcede.org/xcede-2'})[0].text)
        for k, t in (('SNR', float), ('SFNR', float), ('scandate', str), ('drift',float), ('mean',float),('rdc',float), ('ghostPercent',float))
        })


frame = pd.DataFrame(data)

df=frame.set_index(frame.scandate)

df.to_excel("/dartfs/rc/lab/D/DBIC/DBIC/QA/qaplots/boldp2_summary.xls")
