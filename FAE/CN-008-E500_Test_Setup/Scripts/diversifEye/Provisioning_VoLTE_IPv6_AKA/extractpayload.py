""" TM500 LTE Software
    (C) Aeroflex Incorporated 2011
    Longacres House
    Six Hills Way
    Stevenage
    Hertfordshire, SG1 2AN, UK
    Phone: +44 1438 742200

---------------------------------------------------

    Title:         Extract Payload to XML

    Author:        Matthew Pattman
    Version:       1.0
    Date:          10th July 2013

    Notes:         Python is a layout critical
                   language.  Check indentation!

--------------------------------------------------- """

# Import Python libraries and Modules
import sys
import os
import getopt
import string
import base64
import tarfile
import re
from xml.dom.minidom import parse

target_xml_filename = "TM500.xml"

python_ver_info = sys.version_info
if python_ver_info[0] != 2:
    print ""
    print "Python version 2.x is required."
    print ""
    sys.exit(1)

if len(sys.argv) > 1:
    base64.decode(open(sys.argv[1]), open("TM500_tmp.tar.gz", "wb"))
    tfile = tarfile.open("TM500_tmp.tar.gz", 'r:gz')
    tfile.extractall('TM500_tmp')
    tfile.close()
    os.remove("TM500_tmp.tar.gz")

    os.chdir("TM500_tmp")

    dom=parse(target_xml_filename)
    prettyXML=dom.toprettyxml("\t","\n","utf-8")
    fixXML = re.compile(r'((?<=>)(\n[\t]*)(?=[^<\t]))|(?<=[^>\t])(\n[\t]*)(?=<)')
    prettyXML = re.sub(fixXML, '', prettyXML)
    prettyXML=prettyXML.replace("\t","    ")

    # Write XML to stdout
    f = open(target_xml_filename,'w')
    f.write(prettyXML)
    f.close()

    os.chdir("..")

else:
    print ""
    print "python extractpayload.py <file name containg the payload *only* from the MCI command>"
    print ""
    sys.exit(1)

