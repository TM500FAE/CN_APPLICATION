""" TM500 LTE Software
    (C) Aeroflex Incorporated 2014
    Longacres House
    Six Hills Way
    Stevenage
    Hertfordshire, SG1 2AN, UK
    Phone: +44 1438 742200

---------------------------------------------------

    Title:         diversifEye provisioning script

    Author:        Matthew Pattman
    Version:       3.3.0
    Date:          22th February 2016

    Notes:         Python is a layout critical
                   language.  Check indentation!

--------------------------------------------------- """

# Import Python libraries and Modules
import sys
import os
import getopt
import logging
import telnetlib
import string
from ftplib import FTP

# Set the global variables
DLE_USERNAME = "cli"
DLE_PASSWORD = "diversifEye"

PERL_FILE_NAME = "TM500.pl"
PERL_CFG_FILE_NAME = "TM500.xml"

LOG_FILE_NAME = 'shenick.log'
COMMAND_TIMEOUT = 300


USE_SECURE = False
DO_LOGGING = True


class AflxLogging():
    """
    Logging class wrapper to allow logging to be disabled easily.
    """
    def __init__(self, do_logging=True):
        """
        Constructor for the logging
        """
        self.do_logging = do_logging

        if self.do_logging:
            self.log_file_name = LOG_FILE_NAME
            if os.path.exists(self.log_file_name):
                os.remove(self.log_file_name)

            logging.basicConfig(level=logging.DEBUG,
                                 format='%(asctime)s %(levelname)s %(message)s',
                                      filename=self.log_file_name, filemode='a')
            self.log = logging.getLogger("")
        return

    def info(self, entry_str):
        """
        Logging for the info level
        """
        entry_str = entry_str.replace("\r", "").rstrip("\n")
        if self.do_logging:
            self.log.info(entry_str)
        print " - %s" % entry_str
        return

    def warn(self, entry_str):
        """
        Logging for the warning level
        """
        entry_str = entry_str.replace("\r", "").rstrip("\n")
        if self.do_logging:
            self.log.warn(entry_str)

    def debug(self, entry_str):
        """
        Logging for the debug level
        """
        entry_str = entry_str.replace("\r", "").rstrip("\n")
        if self.do_logging:
            self.log.debug(entry_str)
        return

    def error(self, entry_str):
        """
        Logging for the error level
        """
        entry_str = entry_str.replace("\r", "").rstrip("\n")
        if self.do_logging:
            self.log.error(entry_str)
        print "ERROR: %s" % entry_str
        return


def print_usage():
    """
    Prints the script command line options
    """
    print ""
    print "Invocation will be as follows for provisioning (from the folder " \
          "where TMA has installed it):"
    print "python shenick.py <dELite ip> [-p <user_id>] -c provision " \
          "[-x <xml_filename>] [-g <test_group_name>]"
    print ""
    print "Or for XML file upload (and Test Group load):"
    print ""
    print "python shenick.py <dELite ip> [-p <user_id>] -c upload " \
          "-x <xml_filename> -g <test_group_name>"
    print ""
    sys.exit(1)
    return


def print_error(error_type, error_value, error_str=""):
    """
    Prints the error messages
    """

    exit_code = 999;
    if USE_SECURE:
        LOG.error("Secure protocols are not supported yet.")

    elif error_type == "provision":
        exit_code = 100 + error_value
        if error_value == 1:
            LOG.error("There was a syntax error in the provisioning Perl " \
                      "script.  Please check the logfile '%s' for details." %
                      LOG_FILE_NAME)
        elif error_value == 2:
            LOG.error("There was a problem with the provisioning Perl " \
                      "script, has it been modified?  Please check " \
                      "the logfile '%s' for details." % LOG_FILE_NAME)
        elif error_value == 3:
            LOG.error("The provisioning Perl script did not complete " \
                      "within the timeout (%ss).  Please check " \
                      "the logfile '%s' for details." % (COMMAND_TIMEOUT, LOG_FILE_NAME))
        else:
            LOG.error("There was an error in the provisioning commands or " \
                      "the Perl script.  Please check the logfile '%s' " \
                      "for details." % LOG_FILE_NAME)

    elif error_type == "uploadXML" and not USE_SECURE:
        exit_code = 200 + error_value
        if error_value == 1:
            LOG.error("Upload of the XML file by FTP failed, please check " \
                      "the IP address, username, password and permissions")
        else:
            LOG.error("Upload of the XML file by FTP failed, please check " \
                      "the file and user permissions")
    elif error_type == "uploadXML" and USE_SECURE:
        exit_code = 200 + error_value
        LOG.error("Upload of the XML file by SCP failed, please check " \
                  "the file and user permissions")

    elif error_type == "loadTestGroup":
        exit_code = 300 + error_value
        if error_value == 1:
            LOG.error("The cli command was not found during the loading of " \
                      "the test group")
        if error_value == 2:
            exceptStart = error_str.find("com.shenick.diversifeye.")
            if exceptStart > -1:
                error_str = error_str[exceptStart:]

            # Only get the first two lines of the assert as these tell us why.
            error_array = error_str.split("\r")
            error_str = "%s\n%s" % (error_array[0], error_array[1]);

            LOG.error("The diversifEye had an assert or exception during the loading of " \
                      "the test group:\n\n%s\n\n" % error_str)
        else:
            LOG.error("Loading of the test group failed.  Please check " \
                      "the logfile '%s' for details." % LOG_FILE_NAME)

    elif error_type == "missingFile":
        exit_code = 700 + error_value
        LOG.error("The file '%s' is missing" % error_str)

    elif error_type == "wrongPyVersion":
        exit_code = 800
        LOG.error("Unsupported Python version, please use Python 2.x.")

    else:
        exit_code = 900 + error_value
        LOG.error("Unknown Error [%s (%d)]" % (error_type, error_value))

    sys.exit(exit_code)
    return


def load_test_group(host, group_name, partition_id, xml_filename=None):
    """
    load of the test group.
    """
    if xml_filename == None:
        xml_filename = "%s.xml" % group_name

    running_str = "<<<Running>>>"

    check_cmd = "cli -u tm500 -p %s listTestGroups | grep -c %s" % (
                                                      partition_id, group_name)

    check_running_cmd = "cli -u tm500 -p %s listTestGroups | grep -c \"%s.*%s\"" % (
                                partition_id,  group_name, running_str)

    stop_cmd = "cli -u tm500 -p %s stopTestGroup %s" % (
                                                     partition_id,  group_name)

    delete_cmd = "cli -u tm500 -p %s deleteTestGroup %s" % (
                                                     partition_id,  group_name)

    import_cmd = "cli -u tm500 -p %s importTestGroup // %s" % (
                                                    partition_id,  xml_filename)

    LOG.info("Checking if the test group already exists")
    (ret_value, ret_str) = send_commands_to_diversifeye(host, check_cmd)
    LOG.debug("From diversifEye:\n%s" % ret_str)

    if ret_value == 0:
        # Check for not [0] in the reply
        if ret_str.find("cli: command not found") > -1:
            ret_value = 1
        else:
            resp_array = ret_str.split("\r")
            check_cmd_found = False
            check_cmd_resp = ""
            for line in resp_array:
                if check_cmd_found:
                    check_cmd_resp = line.replace("\n", "")
                    break

                if line.find("$ %s" % check_cmd) > -1:
                    check_cmd_found = True

            if check_cmd_resp and check_cmd_resp.find("0") == -1:

                LOG.info("Checking if the test group is currently running")
                (ret_value, ret_str) = send_commands_to_diversifeye(host, check_running_cmd)
                LOG.debug("From diversifEye:\n%s" % ret_str)
                resp_array = ret_str.split("\r")
                check_running_cmd_found = False
                check_running_cmd_resp = ""
                for line in resp_array:
                    if check_running_cmd_found:
                        check_running_cmd_resp = line.replace("\n", "")
                        break

                    if line.find(running_str) > -1:
                        check_running_cmd_found = True

                if check_running_cmd_resp and check_running_cmd_resp.find("1") > -1:
                    LOG.info("Stoping the test group")
                    (ret_value, ret_str) = send_commands_to_diversifeye(host, stop_cmd)

                LOG.info("Deleting the test group")
                (ret_value, ret_str) = send_commands_to_diversifeye(host, delete_cmd)

            LOG.info("Importing provisioing configuration (XML) file")
            (ret_value, ret_str) = send_commands_to_diversifeye(host, import_cmd)
            LOG.debug("From diversifEye:\n%s" % ret_str)

            if ret_str.find("com.shenick.diversifeye.") > -1:
                ret_value = 2
            else:
                importStart = ret_str.find("Importing from XML file")
                if importStart > -1:
                    ret_str = ret_str[importStart:]
                if ret_str.find("cli: command not found") > -1:
                    ret_value = 1

                elif ret_str.find("ERROR:") > -1:
                    ret_value = 3

    return (ret_value, ret_str)


def provision(host, group_name, partition_number, rat):
    """
    Runs the provisioning commands on the diversifEye
    """
    cmds = [
            "chmod 0777 %s" % PERL_FILE_NAME,
            "perl %s %s %s %s %s > %s.xml" % (PERL_FILE_NAME, PERL_CFG_FILE_NAME,
                                    partition_number, group_name, rat, group_name),
          ]

    (ret_value, ret_str) = send_commands_to_diversifeye(host, cmds)

    LOG.debug("From diversifEye:\n%s" % ret_str)
    if ret_str.find("syntax error") > -1:
        ret_value = 1
    elif ret_str.find("at %s line" % PERL_FILE_NAME) > -1:
        ret_value = 2
    elif ret_str.find("Generation of Test Group Complete") == -1:
        ret_value = 3
    elif ret_str.find("error") > -1:
        ret_value = 4

    return ret_value


def send_file_to_diversifeye(host, file_name_or_list):
    """
    Wrapper function for secure or insecure transfer of the file.
    """
    if USE_SECURE:
        return 1 # TBD: upload_file_scp(...)
    else:
        return upload_file_ftp(host, file_name_or_list)


def upload_file_ftp(host, file_name_or_list):
    """
    Uploads the file(s) to the diversifEye via FTP
    """
    ret_value = 2
    try:
        ftp_client = FTP(host)
        ftp_client.connect(host, 21)
        try:
            ftp_client.login(DLE_USERNAME, DLE_PASSWORD)
            ftp_client.cwd(".")
            if isinstance(file_name_or_list, basestring):
                LOG.debug("Uploading file: %s" % file_name_or_list)
                name = os.path.split(file_name_or_list)[1]
                file_handle = open(file_name_or_list, "rb")
                ftp_client.storbinary('STOR ' + name, file_handle)
                file_handle.close()
            else:
                for file_name in file_name_or_list:
                    LOG.debug("Uploading file: %s" % file_name)
                    name = os.path.split(file_name)[1]
                    file_handle = open(file_name, "rb")
                    ftp_client.storbinary('STOR ' + name, file_handle)
                    file_handle.close()
        except:
            ret_value = 2
        else:
            ret_value = 0
        finally:
            ftp_client.quit()
    except:
        ret_value = 1

    return ret_value


def send_commands_to_diversifeye(host, command_or_list):
    """
    Wrapper function for secure or insecure command interface.
    """
    if USE_SECURE:
        return (1, "") # TBD: send_commands_ssh(...)
    else:
        return send_commands_telnet(host, command_or_list)


def send_commands_telnet(host, command_or_list):
    """
    Loads the test group on the diversifEye
    """
    try:
        client = telnetlib.Telnet(host)
    except:
        LOG.error("Failed to connect to the telnet service on %s" % host)
        sys.exit(100)

    try:
        client.read_until("login: ", 10)
    except:
        LOG.error("Failed to read telnet login prompt")
        sys.exit(101)

    client.write(DLE_USERNAME + "\n")
    if DLE_PASSWORD:
        try:
            client.read_until("Password: ", 10)
        except:
            LOG.error("Failed to read telnet password prompt")
            sys.exit(102)
        client.write(DLE_PASSWORD + "\n")

    telnet_resp = ""
    telnet_resp = client.read_until("$ ",10)

    # issue commands
    if not isinstance(command_or_list, basestring):
        for cmd in command_or_list:
            LOG.debug("Sending command: %s" % cmd)
            client.write("%s\n" % cmd)
            telnet_resp += client.read_until("$ ", COMMAND_TIMEOUT)
    else:
        LOG.debug("Sending command: %s" % command_or_list)
        client.write("%s\n" % command_or_list)
        telnet_resp += client.read_until("$ ", COMMAND_TIMEOUT)

    telnet_resp += client.read_very_eager()
    client.close()

    return (0, clean_resp(telnet_resp))


def do_backspace(string_in):
    """
    Removes the backspace and does the backspace action.
    """
    string_out = []
    for c in string_in:
        if c == '\b':
            del string_out[-1:]
        else:
            string_out.append(c)
    return string.join(string_out, '')


def clean_resp(resp):
    """
    Removes excess info from the telnet readall
    """
    ret_str = ""

    start_found = False
    end_found = False

    for line in resp.split("\n"):
        if "$" in line and not start_found and not end_found:
            start_found = True

        if "exit" in line and start_found and not end_found:
            end_found = True

        if start_found and not end_found:
            ret_str += "%s\n" % line

    # If something goes wrong.....
    if ret_str == "":
        ret_str = resp

    return do_backspace(ret_str)




def extract_command_line():
    """
    Extracts the command line parameters
    """
    diversifeye_ip = ""
    user_id = ""
    command = ""
    xml_filename = ""
    test_group_name = ""
    tma_path = ""
    rat = "LTE"
    ret_value = (diversifeye_ip, user_id, command, xml_filename,
                                                      test_group_name, tma_path, rat)

    if len(sys.argv) < 2:
        return ret_value
    else:
        try:
            if "-r" in sys.argv[2:]:
                options = getopt.getopt(sys.argv[2:], "p:c:x:g:r:t:l")
            else:
                options = getopt.getopt(sys.argv[2:], "p:c:x:g:t:l")
        except getopt.GetoptError:
            return ret_value

    diversifeye_ip = sys.argv[1]

    for option_name, option_value in options[0]:
        if option_name == "-p":
            user_id = option_value
        elif option_name in ("-c"):
            command = option_value.lower()
        elif option_name in ("-x"):
            xml_filename = option_value
        elif option_name in ("-g"):
            test_group_name = option_value
        elif option_name in ("-r"):
            rat = option_value
        elif option_name in ("-t"):
            tma_path = option_value[:-1]
        else:
            LOG.debug("Invalid option given (%s = %s)" % (
                                                     option_name, option_value))
            return ret_value

    LOG.debug("Command line options: IP=%s, -p=%s, -c=%s, -x=%s, -g=%s, -t=%s -r=%s" %
                                         (diversifeye_ip, user_id, command,
                                       xml_filename, test_group_name, tma_path, rat))

    return (diversifeye_ip, user_id,
            command, xml_filename, test_group_name, tma_path, rat)


def main():
    """
    Main application
    """

    python_ver_info = sys.version_info
    if python_ver_info[0] != 2:
      print_error("wrongPyVersion", 1)

    (diversifeye_ip, user_id,
    command, xml_filename, test_group_name, tma_path, rat) = extract_command_line()
    if tma_path!="":
        os.chdir(tma_path)

    # Check that the user_id (partition), if set, is between 1 and 6
    if user_id:
        if int(user_id) > 6 or int(user_id) < 1:
            print_usage()

    # Check that we have the correct parameters to perform the operations.
    if (diversifeye_ip and command == "upload" and
                              xml_filename and test_group_name and user_id):
        # Upload XML File and load test group
        LOG.info("Uploading provisioning configuration (XML) file")

        if not os.path.isfile(xml_filename):
            print_error("missingFile", 1, xml_filename)

        ret_val = send_file_to_diversifeye(diversifeye_ip, xml_filename)
        if ret_val != 0:
            print_error("uploadXML", ret_val)
        else:
            LOG.info("Provisioning configuration (XML) file uploaded")

            if not os.path.isfile(xml_filename):
                 print_error("missingFile", 1, xml_filename)

            (ret_val, ret_str) = load_test_group(diversifeye_ip, test_group_name,
                                      user_id, xml_filename)
            if ret_val != 0:
                print_error("loadTestGroup", ret_val, ret_str)

    elif (diversifeye_ip and command == "upload" and xml_filename):
        # Upload XML File
        LOG.info("Uploading the provisioning configuration (XML) file")

        if not os.path.isfile(xml_filename):
             print_error("missingFile", 1, xml_filename)

        ret_val = send_file_to_diversifeye(diversifeye_ip, xml_filename)
        if ret_val != 0:
            print_error("uploadXML", ret_val)
        else:
            LOG.info("Provisioning configuration (XML) file uploaded")

    elif (diversifeye_ip and command == "provision" and
                            test_group_name and user_id and user_id):
        # Provision
        LOG.info("Uploading perl provisioning script")

        if not os.path.isfile(PERL_FILE_NAME):
             print_error("missingFile", 0, PERL_FILE_NAME)
        if not os.path.isfile(PERL_CFG_FILE_NAME):
             print_error("missingFile", 1, PERL_CFG_FILE_NAME)

        ret_val = send_file_to_diversifeye(diversifeye_ip,
                              (PERL_FILE_NAME, PERL_CFG_FILE_NAME))

        if ret_val != 0:
            print_error("uploadPerl", ret_val)
        else:
            LOG.info("Provisioning files uploaded")
            LOG.info("Starting to generate provisioning configuration (XML)")
            ret_val = provision(diversifeye_ip, test_group_name, user_id, rat)
            if ret_val != 0:
                print_error("provision", ret_val)
            else:
                LOG.info("Provisioning configuration (XML) generated")
                (ret_val, ret_str) = load_test_group(diversifeye_ip,
                                          test_group_name, user_id)
                if ret_val != 0:
                    print_error("loadTestGroup", ret_val, ret_str)
    else:
        # Unknown command
        print_usage()

    if ret_val == 0:
        LOG.info("Finished")

    sys.exit(ret_val)
    return


####################
# main application
####################
LOG = AflxLogging(DO_LOGGING)
main()