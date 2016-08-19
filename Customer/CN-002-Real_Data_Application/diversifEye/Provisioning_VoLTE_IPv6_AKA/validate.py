""" TM500 LTE Software
    (C) Aeroflex Incorporated 2011
    Longacres House
    Six Hills Way
    Stevenage
    Hertfordshire, SG1 2AN, UK
    Phone: +44 1438 742200

-------------------------------------------------

    Title:


    Author:        Matthew Pattman
    Version:       1.0.0

    Notes:         Python is a layout critical
                   language.  Check indentation!

    Required:

    http://www.microsoft.com/en-gb/download/details.aspx?id=6276
    http://starship.python.net/crew/theller/comtypes/#downloads


------------------------------------------------- """

# Import Python libraries and Modules
from comtypes.client import CreateObject
from _ctypes import COMError
import os
import sys

class MsXmlValidator:
  def __init__(self):
    self.msxml_version = 0
    self.dom = self.create_dom()
    self.schemas = self.create_schemas()

  def create_dom(self):
    versions = [6, 4]
    versions.sort(reverse=True)
    dom = None
    for version in versions:
      try:
        prog_id = "Msxml2.DOMDocument.%d.0" % version
        dom = CreateObject(prog_id)
        self.msxml_version = version
        break
      except WindowsError, msg:
        dom = None
    if dom != None:
      dom.async = 0
    return dom

  def create_schemas(self):
    if self.dom == None:
        schemas = None
    else:
        schemas = CreateObject("Msxml2.XMLSchemaCache.%d.0" % self.msxml_version)
    return schemas

  def get_namespace(self, xsd_file):
    namespace = ''
    if self.dom != None:
        self.dom.load(xsd_file)
        self.dom.setProperty("SelectionLanguage", "XPath")
        try:
            node = self.dom.documentElement.selectSingleNode("/*/@targetNamespace")
        except:
            return namespace
        if node:
          namespace = node.text
    return namespace

  def add_schema(self, namespace, xsd_file):
    if self.dom != None:
        try:
            self.schemas.add(namespace, xsd_file)
        except COMError, msg:
            return (1, msg)
        self.dom.schemas = self.schemas
    return (0, "")

  def validate_xml_file(self, xml_file, xsd_file):
    if self.dom == None:
        return (99, "")
    else:
        if not os.path.exists(xml_file):
            return (2, "")
        if not os.path.exists(xsd_file):
            return (3, "")
        namespace = self.get_namespace(xsd_file)
        (ret_val, msg) = self.add_schema(namespace, xsd_file)
        if ret_val > 0:
            return (4, msg)
        else:
            if self.dom.load(xml_file):
                return (0, "")
            else:
                return (1, self.dom.parseError)



if len(sys.argv) == 3:
    validator = MsXmlValidator()
    (result, error) = validator.validate_xml_file(sys.argv[1], sys.argv[2])

    if result == 1:
        print "%s: Validation Error" % sys.argv[1]
        print "- Error Code : %s" % error.errorCode
        print "- Reason     : %s" % error.reason.strip()
        print "- Character  : %s" % error.filepos
        print "- Line       : %s" % error.line
        print "- Column     : %s" % error.linepos
        print "- Source     : %s" % error.srcText
    elif result == 2:
        print "XML File Not Found"
    elif result == 2:
        print "XSD File Not Found"
    elif result == 4:
        print 'Error in XML Schema: %s' % sys.argv[2]
        print error
    elif result == 99:
        print "No compatible MSXML versions found on this system"
    else:
        print "XML is valid"
else:
    print 'Usage: %s <xml_file> <xsd_file>' % sys.argv[0]

