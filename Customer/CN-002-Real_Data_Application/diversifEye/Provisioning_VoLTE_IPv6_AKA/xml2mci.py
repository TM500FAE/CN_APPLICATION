""" TM500 LTE Software
    (C) Aeroflex Incorporated 2011
    Longacres House
    Six Hills Way
    Stevenage
    Hertfordshire, SG1 2AN, UK
    Phone: +44 1438 742200

---------------------------------------------------

    Title:         XML 2 MCI

    Author:        Matthew Pattman
    Version:       1.1
    Date:          27th September 2013

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
import shutil
import re
from xml.dom import minidom
from xml.parsers.expat import ExpatError


python_ver_info = sys.version_info
if python_ver_info[0] != 2:
    print ""
    print "Python version 2.x is required."
    print ""
    sys.exit(1)

if len(sys.argv) > 4:
    diversifeye_lite_ip = sys.argv[1]
    partition = sys.argv[2]
    test_group_name = sys.argv[3]
    xml_filename = sys.argv[4]
    if len(sys.argv) > 5:
        perl_filename = sys.argv[5]
    else:
        perl_filename = "TM500.pl"
    target_xml_filename = "TM500.xml"
    target_perl_filename = "TM500.pl"

    if (os.path.isfile(xml_filename) and os.path.isfile(perl_filename)) :

        if (os.path.isfile("TM500_tmp")):
            os.remove("TM500_tmp")
        if (os.path.isdir("TM500_tmp")):
            shutil.rmtree("TM500_tmp", True)

        os.mkdir("TM500_tmp")
        shutil.copyfile(xml_filename, "TM500_tmp/%s" % target_xml_filename)
        shutil.copyfile(perl_filename, "TM500_tmp/%s" % target_perl_filename)
        os.chdir("TM500_tmp")

        # Clean up xml
        try:
          dom=minidom.parse(target_xml_filename)
          prettyXML=dom.toprettyxml("","","utf-8")

          comments = re.compile('<!--.*?-->')
          prettyXML=re.sub(comments,"",prettyXML)
          prettyXML=prettyXML.replace("\t","")
          prettyXML=prettyXML.replace('"?><','"?>\n<')

          trails = re.compile(' *\n')
          prettyXML=re.sub(trails,"",prettyXML)
          prettyXML=re.sub("  +","",prettyXML)

          f = open(target_xml_filename,'w')
          f.write(prettyXML)
          f.close()

        except ExpatError as (expatError):
          sys.stderr.write("Bad XML: line "+str(expatError.lineno)+" offset "+str(expatError.offset)+"\n")
          exit

        tar = tarfile.open("../TM500_tmp.tar.gz", "w:gz")
        for name in [target_xml_filename, target_perl_filename]:
            tar.add(name)
        tar.close()

        os.chdir("..")
        with open("TM500_tmp.tar.gz", "rb") as gz_file:
            encoded_string = base64.b64encode(gz_file.read())

        shutil.rmtree("TM500_tmp", True)
        os.remove("TM500_tmp.tar.gz")

        print "forw mte deProvisionDiversifEye %s %s %s %s" % (diversifeye_lite_ip, partition, test_group_name, encoded_string)

    else:
        print "unable to open XML file or TM500.pl file"
else:
    print ""
    print "python xml2mci.py <dELite ip> <partition> <test_group_name> <xml_filename> <optional perl_filename>"
    print ""
    sys.exit(1)

