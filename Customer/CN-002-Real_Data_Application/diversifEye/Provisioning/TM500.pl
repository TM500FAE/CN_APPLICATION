#!/usr/bin/perl
# -------------------------------------------------
#    TM500 LTE Software
#    (C) Cobham Wireless 2016
#    Longacres House
#    Six Hills Way
#    Stevenage
#    Hertfordshire, SG1 2AN, UK
#    Phone: +44 1438 742200
#
# -------------------------------------------------
#
#    Title:       DiversifEye Provisioning
#
#    Version:     3.6.1
#    Date:        12th April 2016
#
# -------------------------------------------------

### Import Libraries
use diversifEye::TestGroup();
use diversifEye::Misc qw(Name);
use diversifEye::Mac();
use XML::Mini::Document;
use NetAddr::IP;
use POSIX;
use Math::BigInt;

##no warnings;

our $VERSION_STR = $diversifEye::TestGroup::VERSION;
$VERSION_STR =~s/[^\d.]//g;   # Get just the numeric part.
@versionParts = split("\\.", $VERSION_STR);
our $VERSION = $versionParts[0].".".$versionParts[1];

my $ADMIN_PAGE_PORT = 80;
my $POOL_MGR_ADDRESS = "";
my $CHASSIS_TYPE = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/admin\/system\/chassis\/ -O - | grep -o 'CHASSIS_TYPE=[^<]*'/;
if ($CHASSIS_TYPE eq "")
{
  $ADMIN_PAGE_PORT = 8181;
  $CHASSIS_TYPE = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/admin\/system\/chassis\/ -O - | grep -o 'CHASSIS_TYPE=[^<]*'/;
}
$CHASSIS_TYPE =~ s/\r//g; $CHASSIS_TYPE =~ s/\n//g; $CHASSIS_TYPE =~ s/CHASSIS_TYPE=//g;
$CHASSIS_TYPE =~ s/diversifEye-LiTE/500/g;
$CHASSIS_TYPE =~ s/d500/500/g;
$CHASSIS_TYPE =~ s/d1000/1000/g;
$CHASSIS_TYPE =~ s/diversifEye_VMC/TeraVM/g;
$CHASSIS_TYPE =~ s/TeraVM_RDA/TeraVM/g;  # New TeraVM

my $num_args = $#ARGV + 1;
my $server_target = $ARGV[0];
$server_target=~m/(.*)\.xml$/;
my $diversifEyeUser = $ARGV[1];
if (($diversifEyeUser < 1) || ($diversifEyeUser > 6)) {
  printf(STDERR "error: partition id (%s) must be between 1 and 6\n", $diversifEyeUser);
  exit 1;
}
my $TestGroupName = $ARGV[2];
my $TestGroupDesc = "";
my $RatType = "LTE";
my $OverridePppoePrefix = "";
if ($num_args >= 4) {
  if ((uc($ARGV[3]) eq "LTE") || (uc($ARGV[3]) eq "UMTS") || (uc($ARGV[3]) eq "MULTI"))  {
     $RatType = uc($ARGV[3]);
  }
  elsif (((index($ARGV[3], ".") != -1) || (index($ARGV[3], "_") != -1)) && ($VERSION >= 11.3)) {
     $OverridePppoePrefix = $ARGV[3];
  }
}

my $OverrideVlanId = 0;
if (($num_args >= 5) && ($VERSION >= 11.3)) {
   if (($ARGV[4] > 0) && ($ARGV[4] < 4095)) {
      if ($CHASSIS_TYPE eq "TeraVM") {
        $OverrideVlanId = $ARGV[4];
      }
      elsif (($CHASSIS_TYPE eq "500") || ($CHASSIS_TYPE eq "1000")) {
         if ($ARGV[4] != ($diversifEyeUser + 9)) {
            printf(STDERR "Warning: supplied VLAN Id '%s' does not match expected '%s'\n", $ARGV[4], ($diversifEyeUser + 9));
         }
      }
   }
}

if (($CHASSIS_TYPE eq "TeraVM") && ($VERSION <= 99.9)) {
  printf(STDERR "Warning: IPv6/IPv4 Dual Stack (RFC 4241) is not supported on this platform\n");
}

my $CORE_EDGE_ENABLED = 0;
if (($CHASSIS_TYPE eq "500") || ($CHASSIS_TYPE eq "1000")) {
  if ($VERSION >= 12.0) {
      $CORE_EDGE_ENABLED = qx/wget -q --header 'Accept: application\/vnd.cobham.v1+json' http:\/\/127.0.0.1:8080\/poolmanager\/api\/testModules\/ -O - | grep -c 'pp-20-0'/;
  }
  else {
      $CORE_EDGE_ENABLED = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1\/admin\/system\/chassis\/ -O - | grep -c '20\/1,[^<]*'/;
  }
  $CORE_EDGE_ENABLED =~ s/\r//g; $CORE_EDGE_ENABLED =~ s/\n//g;
  if ($CORE_EDGE_ENABLED >= 1) {
    $CORE_EDGE_ENABLED = 1;;
    printf(STDERR "Info: Core-Edge configuration detected\n");
  }
}

$POOL_MGR_ADDRESS = "";
if ($VERSION >= 12.0) {
  $POOL_MGR_ADDRESS = "127.0.0.1";
  if ($CHASSIS_TYPE eq "TeraVM") {
    $POOL_MGR_ADDRESS = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/teraVM\/postInstallConfiguration\/ -O - | grep -oP '(?<=name="CtlServerIp" value=").*?(?=")'/;
    $POOL_MGR_ADDRESS =~ s/\r//g; $POOL_MGR_ADDRESS =~ s/\n//g;
    printf(STDERR "Info: Pool Manager IP %s\n", $POOL_MGR_ADDRESS);
  }
}

my $DEFINED_NUM_PARTITIONS = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/admin\/system\/chassis\/ -O - | grep -o 'num_partitions=[^<]*'/;
$DEFINED_NUM_PARTITIONS =~ s/\r//g; $DEFINED_NUM_PARTITIONS =~ s/\n//g; $DEFINED_NUM_PARTITIONS =~ s/num_partitions=//g;

my @PARTITION_INTERFACES = ();
if (($VERSION >= 11.3) && ($VERSION < 12.0)) {
  my $PART_INFO = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/webservice\/multiuser\/partitions -O -/;
  my @partition_array =  $PART_INFO =~/{(.+?)}/sig;

  foreach my $loop_variable (@partition_array) {
    if (index($loop_variable, '"number":'.$diversifEyeUser) != -1) {
      @if_str = $loop_variable =~/\[(.+?)\]/sig;
      if (@if_str) {
         @PARTITION_INTERFACES = split(',', $if_str[0]);
      }
    }
  }
}

my %GLOBAL_CFG_CMDS = ();
if ($VERSION >= 11.3) {
   my $config_page = qx/wget -q http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/admin\/global\/index.php?pp=10\/1 -O -/;
   my @config_tables = $config_page =~/<table(.+?)<\/table>/sig;
   $config_page = "";

   my $cmdtxt = "";
   my $cmdname = "";
   my $cmdsection = "";
   my $cmdvalue = "";

   foreach my $table (@config_tables) {
      $cmdsection = "";
      if (index($table, "summary=") != -1) {
         ($cmdsection) = $table =~ m/summary="(.+?)"/;
         $cmdsection = $cmdsection."_";
         $cmdsection =~ s/^\s+|\s+$//g;
         $cmdsection =~ s/ |\/|-|\+/_/g;
         $cmdsection =~ s/\>|"|'|\|\%|\[|\]//sig; $cmdsection =~ s/\.//sig; $cmdsection =~ s/\,//sig; $cmdsection =~ s/\)//g; $cmdsection =~ s/\(//g; $cmdsection = lc($cmdsection);
      }
      @table_rows = $table =~/<tr>(.+?)<\/tr>/sig;
      foreach my $row (@table_rows) {
         if (index($row, "name=") != -1) {
            $row =~ s/<td style="width:30%"/<td/g;
            $row =~ s/<td style="width:40%" align=right/<td/g;
            $row =~ s/<td style="width:60%"/<td/g;
            $row =~ s/://g;
            @column = $row =~/<td>(.+?)<\/t/sig;
            $cmdtxt = ""; $cmdname = ""; $cmdvalue = "";
            foreach $cell (@column) {
               if ($cmdname eq "") {
                  if (index($cell, "name=") != -1) {
                     ($cmdname) = $cell =~ m/name="(.+?)"/;
                  }
               }
               if ($cmdvalue eq "") {
                  if (index($cell, "value=") != -1) {
                     ($cmdvalue) = $cell =~ m/value="(.+?)"/;
                  }
               }
               if ($cmdtxt eq "") {
                  if (index($cell, "<") != -1) {
                     $cmdtxt = substr($cell, 0, index($cell, '<'));
                  } else {
                     $cmdtxt = $cell;
                  }
               }
               if (($cmdtxt ne "") && ($cmdname ne "")) {
                  $cmdtxt =~ s/^\s+|\s+$//g;
                  $cmdtxt =~ s/\=| |\/|-|\+/_/g;
                  $cmdtxt =~ s/\>|"|'|\|\%|\[|\]//sig; $cmdtxt =~ s/\.//sig; $cmdtxt =~ s/\,//sig; $cmdtxt =~ s/\)//g; $cmdtxt =~ s/\(//g; $cmdtxt = lc($cmdtxt);
                  $cmdname =~ s/^\s+|\s+$//g;
                  $suffix = ""; $suffixNum = 0;
                  while (1) {
                     if (exists $GLOBAL_CFG_CMDS{$cmdsection.$cmdtxt.$suffix}) {
                        $suffixNum = $suffixNum + 1; $suffix = "_".$suffixNum;
                     } else {
                       last;
                     }
                  }
                  $GLOBAL_CFG_CMDS{$cmdsection.$cmdtxt.$suffix} = $cmdname;
                  $GLOBAL_CFG_VALUES{$cmdname} = $cmdvalue;
                  $cmdtxt = ""; $cmdname = ""; $cmdvalue ="";
               }
            }
         }
      }
   }
}

### Global and default variables
my $Clo = diversifEye::Misc->GetStandardOptions();
my $AsOther = 'Enabled';
my $ServiceState = 'Out of Service';

my $PooledConfig = 0;
my $PooledTopology = "SUT";
my $PooledSgiPrefix = $PooledTopology."-sgi";
my $PooledSgiLowPrefix = $PooledTopology."-sgilow";
my $PooledUePrefix = $PooledTopology."-ue";
my $PooledUeLowPrefix = $PooledTopology."-uelow";
my $ProcessingMaxUnits = 1;

#                        (UEs x PDNs x Apps) + Hosts for apps + Gateways
my $MaxEntityD500    = (3000  * 2 * 2)  + 2  + 2;
my $MaxEntityD1000   = (6000  * 2 * 2)  + 4  + 2;
my $MaxEntityD1000CE = (12000 * 2 * 2)  + 4  + 2;
my $MaxEntityRda630  = (36000 * 8 * 10) + 10 + 2;

my $TotalPPPoEHosts = 0;
my $TotalAppHosts = 0;
my $TotalHosts = 0;
my $TotalApps = 0;
my $TotalEntities = 0;

### Default Values
my $bPingTargetIp =  "4.2.2.2";
my $bPingPayloadSize = 100;
my $bPingInterval = 5000;

my $MaskBits = 16;
my $v6_MaskBits = 64;
my $ClientBits = 16;

my $ReduceOnOff = "0";
my $DiversifEyeType = "500";
my $MinimumUeIdDigits = 3;

my @diversifEyePaVoipVideoCodecs = diversifEye::Codec->VideoAvailable();
my @diversifEyePaRtpVideoCodecs = diversifEye::Codec->VideoAvailable();
my @diversifEyePaRtpAudioCodecs = diversifEye::Codec->AudioAvailable();

my @diversifEyeDefaultCodecs = @{$diversifEye::RtpCodec::DefaultNames};
my @createdCodecs = @diversifEyeDefaultCodecs;

my $FtpPutEnabled = 0;
my $FtpGetEnabled = 0;
my $HttpEnabled = 0;
my $VoipEnabled = 0;
my $RtspEnabled = 0;
my $TwampEnabled = 0;
my $SpingEnabled = 0;
my $CpingEnabled = 0;
my $TeraFlowEnabled = 0;
my $ImgpEnabled = 0;
my $MldEnabled = 0;

my $FtpServerEnabled = 0;
my $HttpServerEnabled = 0;
my $VoipServerEnabled = 0;
my $RtspServerEnabled = 0;
my $TwampServerEnabled = 0;
my $PingServerEnabled = 0;
my $TeraFlowServerEnabled = 0;
my $ImgpServerEnabled = 0;
my $MldServerEnabled = 0;

## Application Specific
my $FtpServer = 'FTPServer';
my $FtpGetPath = 'test.dat';
my $FtpPutPath = '';
my $FtpGetMode = 'Passive';
my $FtpPutMode = 'Passive';

my $Rd = $Clo->{ResourceDirectory};

my $FtpPutPathShared = 'FtpPutPathShared';
my $FtpPutPathIsShared = 0;
my $FtpIsAnonymous = 'true';
my $FtpUsername = '';
my $FtpPassword = '';
my $FtpDelayBetweenCommands = 50;
my $FtpDelayBetweenSessions = 50;
my $FtpFileSize = 1048576;
my $HttpServer = 'HTTPServer';
my $HttpGetPath = '/';
my $HttpFileSize = 15360;  # 15 Kb
my $HttpUsername = '';
my $HttpPassword = '';
my $HttpOperation = 'GET';
my $HttpDelayBetweenCommands = 50;
my $HttpDelayBetweenSessions = 50;
my $HttpPostContent = '';
my $HttpTlsSupportNeeded = 0;

my $bPingEnabled = 1;
my $ue = 0;

my $defaultPingTargetIp =  "0.0.0.0";
my $defaultbPingPayloadSize = 100;
my $defaultPingInterval = 5000;
my $defaultPingStartAfter = 0;
my $defaultPingStopAfter = "";
my $defaultPingEnabled = 1;

my $defaultSIPDomain = "default.com";

my $SIPServer = 'SIPServer';
my $SIPUsername = '';
my $SIPPassword = '';
my $SIPDomain = '';
my $SIPProxy = '';
my $SIPRegisterWithServer = 'true';
my $SIPAverageHoldTime = 600;
my $SIPBHCA = 1;
my $SIPAllowDelayBetweenCalls = 'false';
my $SIPDestinationCallURIType = '';
my $SIPTransportPort = '5060';
my $SIPTransportType = "UDP";

my @InternalVoIPServerNames = ();
my @InternalTFServerNames = ();
my @InternalIgmpServerNames = ();
my @InternalMldServerNames = ();
my %InternalTFServerIp = ();
my %InternalIgmpServerIp = ();
my %InternalMldServerIp = ();
my @InternalHostNames = ();
my @ServerNames = ();

my $RtspServer = 'RTSPServer';
my $RtspPath = '/';
my $RtspUsername = '';
my $RtspPassword = '';
my $RtspDelayBetweenSessions = 50;
my $RtspMediaStreamMethod = 'UDP';
my $RtspUseInitialAuthentication = 'false';
my $RtspMediaTransport = 'RTP';
my $RtspMediaInactivityTimeout = '1000';

my $RtspMediaStreamDuration = 'Period of Time';
my $RtspMediaStreamAmountOfData = '10240';

my $RtspMediaStreamDurationPeriodOfTime = '900';
my $RtspStartAfter = '0';
my $RtspStopAfter = '';

my $TeraFlowServer = "TeraFlowServer";
my $IgmpServer = "IgmpServer";
my $MldServer = "MldServer";

my $CreateMissingLoadProfiles = 0;
my $CreateDefaultPPPoEConnection = 0;

my $doStatisticGroups = 0;
my $NormalStatsEnabled = "true";
my $FineStatsEnabled = "false";
my $LatencyStatsEnabled = "false";


my $TcpCharacteristicsDefault = "default";

my $RtspTransportPortDefault = "554";

my $RtspPortProfileDefault = "RtspPortProfile";
my $RtpPortProfileDefault = "RtpPortProfile";
my $VoipPortProfileDefault = "VoipPortProfile";
my $SilenceProfileDefault = "SilenceProfile";

my $portPrefix = "";

my $defaultGatewayName = "Gateway";
my $defaultIPv6GatewayName = "Gateway_v6";

my $FtpGetCmdListId = "";   # "_GetCmdList"
my $FtpPutCmdListId = "";   # "_PutCmdList"
my $VoipCallListId = "";    # "_CallList_"
my $SmsListId = "_SMS";     # "_SMSList_"
my $HttpRequestListId = ""; #"_RequestList"
my $RtspRequestListId = ""; #"_RequestList"

my $TcpCharFtpGetId = "";   # "_FTP_Get"
my $TcpCharFtpPutId = "";   # "_FTP_Put"
my $TcpCharHttpId = "";     # "_HTTP"
my $TcpCharShttpId = "";    # "_SHTTP"
my $TcpCharVoIPId = "";     # "_VoIP"
my $TcpCharRtspId = "";     # "_RTSP"
my $TcpCharTwampId = "";    # "_TWAMP"
my $TcpCharTeraFlowId = "";
my $v6suffix = "";

my $useScaledEntities = 0;
my $useScaledPadding = "false";

my @VoIPApps = ();
my @IpV6ServerHostNames = ();
my @pppoeGroupList = ();
my $TeraVM_Client_IF = "3";
my $TeraVM_Server_IF = "4";
my $TeraVM_MaxUes_per_tm = 6000;

sub isMacObj {

  ($mac) = @_;
  $retValue = 1;

  if ($mac eq "") {
    $retValue = 0;
  }

  return($retValue);
}

sub cleanAlias {

  $AliasName = $_[0];
  $AliasName =~ s/ /_/g;
  $AliasName =~ s/\"//g;
  $AliasName =~ s/\'//g;
  $AliasName =~ s/\s+//g;
  $AliasName =~ s/[^\040-\176]//g;

  return($AliasName);
}

sub cleanRange {

  ($ueRange, $pdnRange) = @_;

  $ueRange =~ s/\.\./-/g;
  $ueRange =~ s/,/./g;

  $pdnRange =~ s/\.\./-/g;
  $pdnRange =~ s/,/./g;

  $RangeValue = "";
  if ($ueRange ne "") {
    $RangeValue = "_ue".$ueRange;
  }

  if ($pdnRange ne "") {
    $RangeValue = $RangeValue."_pdn".$pdnRange;
  }

  return($RangeValue);
}

sub cleanXmlAmp {  # Convert &gt; and &lt;

  $toClean = $_[0];
  $toClean =~ s/&amp;lt;/$lt/;
  $toClean =~ s/&amp;gt;/$gt/;

  return($toClean);
}

sub isInRange {

  no warnings 'uninitialized';

  ($Item, $Range) = @_;
  $Range =~ s/-/\.\./g;
  @values = split(',', $Range);
  foreach my $val (@values) {
    if ($val =~ m/\.\./) {
      ($minVal, $maxVal) = split('\.\.', $val);
      if ($maxVal eq "") { # for the case "x.."
        $maxVal = $conf{UEs};
      }
      if (($Item >= $minVal) && ($Item <= $maxVal)) {
         return (1);
       }
    }
    elsif ($val == $Item) {
       return (1);
    }
  }

  return (0);
}

sub getScaledItems($$;$$) {

 # no warnings 'uninitialized';

  ($thisRange, $thisOddOrEvenOrNone, $thisPdn, $thisMomt) = @_;
  $maxVal = $conf{UEs}-1;
  $minVal = 0;
  $overrideName = "";
  $incrementSize = 1;
  $scaleFactor = 1;

  $thisRange =~ s/-/\.\./g;
  if ($thisRange =~ m/\.\./) {
    ($minVal, $maxVal) = split('\.\.', $thisRange);

    if ($minVal eq "") {
       $minVal = 0;
    }

    if ($maxVal eq "") { # for the case "x.."
      $maxVal = $conf{UEs}-1;
    }
    $overrideName = $minVal."-".$maxVal;
    $scaleFactor = ($maxVal-$minVal+1);

    if ($thisOddOrEvenOrNone eq "Even") {
      $incrementSize = 2;
      $overrideName = $overrideName."_even";
      if ($minVal % 2) {
        $minVal = $minVal + 1;
      }
    }
    elsif ($thisOddOrEvenOrNone eq "Odd") {
      $incrementSize = 2;
      $overrideName = $overrideName."_odd";
      if ($minVal % 2 == 0) {
         $minVal = $minVal + 1;
      }
    }
  }
  else {
    $minVal = $thisRange;
    $maxVal = $thisRange;
    $overrideName = $minVal;
  }

  if (defined $thisMomt) {
    if ($thisMomt ne "") {
      $overrideName = $overrideName."_".$thisMomt;
    }
  }

  if (defined $thisPdn) {
    if ($thisPdn ne "") {
      $overrideName = $overrideName."_pdn".$thisPdn;
    }
  }

  $scaleFactor = floor($scaleFactor/$incrementSize);
  return ($minVal, $incrementSize, $scaleFactor, $overrideName);
}

sub getGlobalParamName {
  ($section, $needle) = @_;
  $section = lc($section);
  $needle = lc($needle);

  $section =~ s/^\s+|\s+$//g;
  $section =~ s/\=| |\/|-|\+/_/g;
  $section =~ s/\>|"|'|\|\%|\[|\]//sig; $section =~ s/\.//sig; $section =~ s/\,//sig; $section =~ s/\)//g; $section =~ s/\(//g;

  $needle =~ s/^\s+|\s+$//g;
  $needle =~ s/\=| |\/|-|\+/_/g;
  $needle =~ s/\>|"|'|\|\%|\[|\]//sig; $needle =~ s/\.//sig; $needle =~ s/\,//sig; $needle =~ s/\)//g; $needle =~ s/\(//g;

  $paramName = "";
  foreach my $key (sort {lc $GLOBAL_CFG_CMDS{$a} cmp lc $GLOBAL_CFG_CMDS{$b} } keys %GLOBAL_CFG_CMDS) {
     if (index($key, $section) == 0) {
        if (index($key, $needle) != -1) {
           $paramName = $GLOBAL_CFG_CMDS{$key};
           last;
        }
     }
  }

  if ($paramName eq "") {
      printf(STDERR "Warning: unable to locate global param '%s' in section '%s'", $needle, $section);
  }

  return($paramName);
}

sub getGlobalParamValue {
   $paramName = $_[0];
   return($GLOBAL_CFG_VALUES{$paramName});
}


### Parse the configuration
unless (-e $server_target)
{
  printf(STDERR "error: Configuration file not found (%s)\n", $server_target);
  exit 1;
}


my $xmlConfig = XML::Mini::Document->new();

eval {
  $xmlConfig->parse($server_target);
};
if ($@) {
  printf(STDERR "error: XML parsing problem of the Configuration file (%s): %s\n", $server_target, $@);
  exit 1;
}

my $xmlHash = $xmlConfig->toHash();

if (!defined $xmlHash->{'diversifEye_Configuration'}) {
  printf(STDERR "error: Configuration file (%s) not missing main section\n", $server_target);
  exit 1;
}

my %hconf;
my %serverHosts;
my $i=0;

my @FtpGetAliasNames = ();
my @FtpPutAliasNames = ();
my @HttpAliasNames = ();
my @ShttpAliasNames = ();
my @VoipAliasNames = ();
my @RtspAliasNames = ();
my @TwampAliasNames = ();
my @PingAliasNames = ();
my @TeraFlowAliasNames = ();
my @IgmpAliasNames = ();
my @MldAliasNames = ();

$defaultFtpGetAlias = "cftp_get";
$defaultFtpPutAlias = "cftp_put";
$defaultHttpAlias = "chttp";
$defaultShttpAlias = "shttp";
$defaultVoipAlias = "cvoip";
$defaultVoimsAlias = "voims";
$defaultRtspAlias = "crtsp";
$defaultTwampAlias = "ctwamp";
$defaultCpingAlias = "cping";
$defaultSpingAlias = "sping";
$defaultTeraFlowAlias = "ctera";
$defaultTeraFlowServerAlias = "stera";
$defaultIgmpAlias = "cigmp";
$defaultMldAlias = "cmld";

$defaultFtpGetDescription = "FTP (GET)";
$defaultFtpPutDescription = "FTP (PUT)";
$defaultHttpDescription = "HTTP";
$defaultHttpsDescription = "HTTPS";
$defaultShttpDescription = "Server Side HTTP";
$defaultShttpsDescription = "Server Side HTTPS";
$defaultVoipDescription = "VoIP";
$defaultVoimsDescription = "VoIMS";
$defaultRtspDescription = "RTSP";
$defaultTwampDescription = "TAWMP";
$defaultCpingDescription = "Client Side Ping";
$defaultSpingDescription = "Server Side Ping";
$defaultTeraFlowDescription = "TeraFlow";
$defaultIgmpDescription = "IGMP";
$defaultMldDescription = "MLD";

$PPPoEIPv6Enabled = 0;
$PPPoEIPv6UeRange = "";
$PPPoEIPv6PdnRange = "";

eval {

  $rootKey = $xmlHash->{'diversifEye_Configuration'};

  if (defined $rootKey->{'Description'}) {
    $TestGroupDesc = $rootKey->{'Description'};
  }

  ### Use alt format
  if (defined $rootKey->{'Use_Reduce'}) {
    if ($rootKey->{'Use_Reduce'} eq 'true') {
      $ReduceOnOff = "1";
    }
  }

  if (defined $rootKey->{'DiversifEye_Type'}) {
    if ($rootKey->{'DiversifEye_Type'} eq '500') {
      $DiversifEyeType = "500";
      $ProcessingMaxUnits = 1;
    }
    elsif ($rootKey->{'DiversifEye_Type'} eq '8400') {
      $DiversifEyeType = "8400";
      $ProcessingMaxUnits = 1;
    }
    elsif ($rootKey->{'DiversifEye_Type'} eq '1000') {
      $DiversifEyeType = "1000";
      $ProcessingMaxUnits = 2;
    }
    if (lc($rootKey->{'DiversifEye_Type'}) eq 'teravm') {
      $DiversifEyeType = "TeraVM";
      $ProcessingMaxUnits = 2;
    }
  }

  if ($DiversifEyeType ne $CHASSIS_TYPE) {
    if (($CHASSIS_TYPE eq "1000") && ($DiversifEyeType eq "500")) {  #Allow the d1000 to be configured exactly like a d500
      printf(STDERR "warning: configured DiversifEye type (%s) does not match detected chassis type (%s), no corrections applied, configuring d%s as a d%s.\n", $DiversifEyeType, $CHASSIS_TYPE, $CHASSIS_TYPE, $DiversifEyeType);
    }
    else {
      printf(STDERR "warning: configured DiversifEye type (%s) does not match detected chassis type (%s), correcting configuration.\n", $DiversifEyeType, $CHASSIS_TYPE);
      $DiversifEyeType = $CHASSIS_TYPE;
    }
  }

  if (($VERSION >= 11.3) && ($VERSION < 12.0)) {
     if (@PARTITION_INTERFACES) {
        printf(STDERR "Interfaces assigned to this partition / user (%s) are %s.\n", $diversifEyeUser, join(",", @PARTITION_INTERFACES));
     }
     else {
        printf(STDERR "ERROR: NO interfaces have been assigned to this partition / user (%s)\n", $diversifEyeUser);
     }
  }

  if (( ($CHASSIS_TYPE eq "500") || ($CHASSIS_TYPE eq "1000") || ($CHASSIS_TYPE eq "TeraVM") ) && ($VERSION >= 10) ){
     $portPrefix = "1/";
  }

  if (defined $rootKey->{'Create_Statistic_Groups'}) {
    if (lc($rootKey->{'Create_Statistic_Groups'}) eq 'true') {
      $doStatisticGroups = 1;
    }
  }

  $NormalStatsEnabled = "true";
  if (defined $rootKey->{'Normal_Statistics'}) {
    if (lc($rootKey->{'Normal_Statistics'}) eq 'false') {
      $NormalStatsEnabled = "false";
    }
  }

  $FineStatsEnabled = "false";
  if (defined $rootKey->{'Fine_Statistics'}) {
    if (lc($rootKey->{'Fine_Statistics'}) eq 'true') {
      $FineStatsEnabled = "true";
    }
  }

  $LatencyStatsEnabled = "false";
  if (defined $rootKey->{'Latency_Statistics'}) {
    if (lc($rootKey->{'Latency_Statistics'}) eq 'true') {
      $LatencyStatsEnabled = "true";
    }
  }

  $bPingEnabled = 1;
  if (defined $rootKey->{'Background_Ping'}) {
    if (lc($rootKey->{'Background_Ping'}) eq 'false') {
      $bPingEnabled = 0;
    }

    if (defined $rootKey->{'Background_Ping'}->{'Delay_Between_Pings'}) {
      if (($rootKey->{'Background_Ping'}->{'Delay_Between_Pings'} ne "") && ($rootKey->{'Background_Ping'}->{'Delay_Between_Pings'} >= 1) && ($rootKey->{'Background_Ping'}->{'Delay_Between_Pings'} <= 3600000)) {
        $bPingInterval = $rootKey->{'Background_Ping'}->{'Delay_Between_Pings'};
      }
    }

    if (defined $rootKey->{'Background_Ping'}->{'Payload_Size'}) {
      if (($rootKey->{'Background_Ping'}->{'Payload_Size'} ne "") && ($rootKey->{'Background_Ping'}->{'Payload_Size'} >= 41) && ($rootKey->{'Background_Ping'}->{'Payload_Size'} <= 1464)) {
        $bPingPayloadSize = $rootKey->{'Background_Ping'}->{'Payload_Size'};
      }
    }

    if (defined $rootKey->{'Background_Ping'}->{'Ping_IP_Address'}) {
      $bPingTargetIp = $rootKey->{'Background_Ping'}->{'Ping_IP_Address'};
    }
  }

  $doPerPortVoIPProxy = 1;
  if (defined $rootKey->{'Use_per_Port_VoIP_Srv_Proxy'}) {
    if (lc($rootKey->{'Use_per_Port_VoIP_Srv_Proxy'}) eq 'true') {
      $doPerPortVoIPProxy = 1;
    }
    elsif (lc($rootKey->{'Use_per_Port_VoIP_Srv_Proxy'}) eq 'false') {
      $doPerPortVoIPProxy = 0;
    }
  }

  if (defined $rootKey->{'Use_Scaled_Entities'}) {
    if ((lc($rootKey->{'Use_Scaled_Entities'}) eq 'true') && ($VERSION >= 10.5)) {
      $useScaledEntities = 1;
    }
    elsif (lc($rootKey->{'Use_Scaled_Entities'}) eq 'false') {
      $useScaledEntities = 0;
    }
  }

  if (defined $rootKey->{'Use_Scaled_Pad_Increment'}) {
    if (lc($rootKey->{'Use_Scaled_Pad_Increment'}) eq 'true') {
      $useScaledPadding = "true";
    }
  }

  if (($useScaledEntities == 0) && ($DiversifEyeType eq "TeraVM")) {
     $useScaledEntities = 1;
     printf(STDERR "warning: only scaled entities are supported on TeraVM, correcting configuration to enable scaled entities.\n");
  }

  $PooledConfig = 0;
  if (($VERSION >= 12.0) && (($DiversifEyeType eq "TeraVM") || ($DiversifEyeType eq "1000"))) {
    if (defined $rootKey->{'Pooled_Mode'}) {
      if (lc($rootKey->{'Pooled_Mode'}) eq "true") {
        $PooledConfig = 1;
      }
    }
    if (defined $rootKey->{'Processing_Units'}) {
      if ($rootKey->{'Processing_Units'} > 0) {
        $ProcessingMaxUnits = $rootKey->{'Processing_Units'};
      }
    }
    if ($PooledConfig == 0) {
      printf(STDERR "Info: Classic Mode configured with %s Processing Units.\n", $ProcessingMaxUnits);
    }
    else {
      printf(STDERR "Info: Pooled Manager Mode configured with %s Processing Units.\n", $ProcessingMaxUnits);
    }
  }
  $conf{TestGroupName} = $TestGroupName;
  $conf{TestGroupDesc} = $TestGroupDesc;

  if (defined $rootKey->{'Network_Configuration'}) {

    $thisKey = $rootKey->{'Network_Configuration'};

    $conf{domain} = '';  # Unused
    $conf{addr_assignment} = 'PPPoE';

    $conf{TCPWindowScale} = "2";
    $conf{TCPUseSACKWhenPermitted} = "true";
    $conf{TCPSetSACKPermitted} = "true";
    $conf{TCPMaxAdvertisedReceivedWindowSize} = "32768";
    $conf{TCPMaxTransmitBufferSize} = "131072";
    $conf{TCPSupportTimestampWhenRequested} = "true";
    $conf{TCPRequestTimestamp} = "true";

    if (defined $thisKey->{'TCP_Characteristics'}) {
      if (defined $thisKey->{'TCP_Characteristics'}->{'Window_Scale'}) {
        if ($thisKey->{'TCP_Characteristics'}->{'Window_Scale'} eq "") {
          $conf{TCPWindowScale} = $thisKey->{'TCP_Characteristics'}->{'Window_Scale'};
        }
        elsif (($thisKey->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
          $conf{TCPWindowScale} = $thisKey->{'TCP_Characteristics'}->{'Window_Scale'};
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
        if (lc($thisKey->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) eq "true") {
          $conf{TCPUseSACKWhenPermitted} = "true";
        }
        elsif (lc($thisKey->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) eq "false") {
          $conf{TCPUseSACKWhenPermitted} = "false";
        }
        elsif ($thisKey->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "") {
          $conf{TCPUseSACKWhenPermitted} = "false";
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
        if (lc($thisKey->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) eq "true") {
          $conf{TCPSetSACKPermitted} = "true";
        }
        elsif (lc($thisKey->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) eq "false") {
          $conf{TCPSetSACKPermitted} = "false";
        }
        elsif ($thisKey->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "") {
          $conf{TCPSetSACKPermitted} = "false";
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
        if ($thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} eq "") {
          $conf{TCPMaxAdvertisedReceivedWindowSize} = $thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}
        }
        elsif (($thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
          $conf{TCPMaxAdvertisedReceivedWindowSize} = $thisKey->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
        if ($thisKey->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} eq "") {
          $conf{TCPMaxTransmitBufferSize} = $thisKey->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
        }
        elsif ($thisKey->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
          $conf{TCPMaxTransmitBufferSize} = $thisKey->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
        if (lc($thisKey->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) eq "true") {
          $conf{TCPSupportTimestampWhenRequested} = "true";
        }
        elsif (lc($thisKey->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) eq "false") {
          $conf{TCPSupportTimestampWhenRequested} = "false";
        }
        elsif ($thisKey->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "") {
          $conf{TCPSupportTimestampWhenRequested} = "false";
        }
      }
      if (defined $thisKey->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
        if (lc($thisKey->{'TCP_Characteristics'}->{'Request_Timestamp'}) eq "true") {
          $conf{TCPRequestTimestamp} = "true";
        }
        elsif (lc($thisKey->{'TCP_Characteristics'}->{'Request_Timestamp'}) eq "false") {
          $conf{TCPRequestTimestamp} = "false";
        }
        elsif ($thisKey->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "") {
          $conf{TCPRequestTimestamp} = "false";
        }
      }
    }

   $conf{Server_ip} = "132.248.1.200";
   $conf{Client_ip} = "50.1.1.100";
   $conf{Client_GW_ip} = "100.1.1.1";
   $conf{Core_GW_ip} = "10.250.250.250";
   $conf{Gateway_ip} = "132.248.1.1";
   $conf{Client_subnet_ip} = "10.0.0.0";
   $conf{Client_ip_batch_start_addr} = "10.1.1.3";

    ### IPv4
    if (defined $thisKey->{'IPv4'}) {
      if (defined $thisKey->{'IPv4'}->{'Server_IP'}) {
        $conf{Server_ip} = $thisKey->{'IPv4'}->{'Server_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Client_IP'}) {
        $conf{Client_ip} = $thisKey->{'IPv4'}->{'Client_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Client_Gateway_IP'}) {
        $conf{Client_GW_ip} = $thisKey->{'IPv4'}->{'Client_Gateway_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Client_Gateway_IP'}) {
        $conf{Core_GW_ip} = $thisKey->{'IPv4'}->{'Client_Gateway_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Core_Gateway_IP'}) {
        $conf{Core_GW_ip} = $thisKey->{'IPv4'}->{'Core_Gateway_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Gateway_IP'}) {
        $conf{Gateway_ip} = $thisKey->{'IPv4'}->{'Gateway_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Client_Subnet_IP'}) {
        $conf{Client_subnet_ip} = $thisKey->{'IPv4'}->{'Client_Subnet_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Client_IP_Batch_Start_Address'}) {
        $conf{Client_ip_batch_start_addr} = $thisKey->{'IPv4'}->{'Client_IP_Batch_Start_Address'};
      }
      if (defined $thisKey->{'IPv4'}->{'Group_IP'}) {
        $conf{group_ip} = $thisKey->{'IPv4'}->{'Group_IP'};
      }
      if (defined $thisKey->{'IPv4'}->{'Group_IP_Number'}) {
        $conf{group_ip_num} = $thisKey->{'IPv4'}->{'Group_IP_Number'};
      }
      if (defined $thisKey->{'IPv4'}->{'Mask_Bits'}) {
        if (($thisKey->{'IPv4'}->{'Mask_Bits'} > 0) && ($thisKey->{'IPv4'}->{'Mask_Bits'} < 65536)) {
          $MaskBits = $thisKey->{'IPv4'}->{'Mask_Bits'};
          $ClientBits = $MaskBits;
        }
      }
    }

    $conf{v6_Server_ip} = "2001:4711:AFEE:1001:1:1";
    $conf{v6_Client_ip} = "FE80::3000:1100:1";
    $conf{v6_Client_GW_ip} = "2001:4711:AFEE:1001::1";
    $conf{v6_Core_GW_ip} = "2001:4711:AFAA:1001::1";
    $conf{v6_Gateway_ip} = "FE80::3000:1100:1";

    ### IPv6
    if (defined $thisKey->{'IPv6'}) {
      if (defined $thisKey->{'IPv6'}->{'Server_IPv6'}) {
        $conf{v6_Server_ip} = $thisKey->{'IPv6'}->{'Server_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Client_IPv6'}) {
        $conf{v6_Client_ip} = $thisKey->{'IPv6'}->{'Client_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Client_Gateway_IPv6'}) {
        $conf{v6_Client_GW_ip} = $thisKey->{'IPv6'}->{'Client_Gateway_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Client_Gateway_IPv6'}) {
        $conf{v6_Core_GW_ip} = $thisKey->{'IPv6'}->{'Client_Gateway_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Core_Gateway_IPv6'}) {
        $conf{v6_Core_GW_ip} = $thisKey->{'IPv6'}->{'Core_Gateway_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Gateway_IPv6'}) {
        $conf{v6_Gateway_ip} = $thisKey->{'IPv6'}->{'Gateway_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Group_IPv6'}) {
        $conf{v6_group_ip} = $thisKey->{'IPv6'}->{'Group_IPv6'};
      }
      if (defined $thisKey->{'IPv6'}->{'Group_IPv6_Number'}) {
        $conf{v6_group_ip_num} = $thisKey->{'IPv6'}->{'Group_IPv6_Number'};
      }
      if (defined $thisKey->{'IPv6'}->{'Mask_Bits'}) {
        if (($thisKey->{'IPv6'}->{'Mask_Bits'} > 0) && ($thisKey->{'IPv6'}->{'Mask_Bits'} < 65536)) {
          $v6_MaskBits = $thisKey->{'IPv6'}->{'Mask_Bits'};
        }
      }
    }
  }

  ### TM500
  if (defined $rootKey->{'TM500'}) {

    $thisKey = $rootKey->{'TM500'};

    $conf{UEs} = $thisKey->{'Total_UEs'};
    $conf{PDNs_per_UE} = 1;
    if (defined $thisKey->{'PDNs_per_UE'}) {
      if (($thisKey->{'PDNs_per_UE'} >= 1) && ($thisKey->{'PDNs_per_UE'} <= 8)) {
        $conf{PDNs_per_UE} = $thisKey->{'PDNs_per_UE'};
      }
    }
    $conf{TM500_LAN_IP} = $thisKey->{'LAN_IP'};

    if (defined $thisKey->{'Minimum_UE_ID_Digits'}) {
      if (($thisKey->{'Minimum_UE_ID_Digits'} >= 1) && ($thisKey->{'Minimum_UE_ID_Digits'} <= 5)) {
        $MinimumUeIdDigits = $thisKey->{'Minimum_UE_ID_Digits'};
      }
    }
  }
  $TotalPPPoEHosts = $conf{UEs} * $conf{PDNs_per_UE};

  ### PPPoE
  $PPPoEIPv6Enabled = 0;
  $PPPoEIPv6UeRange = "";
  $PPPoEIPv6PdnRange = "";

  if (defined $rootKey->{'PPPoE'}) {

    $thisKey = $rootKey->{'PPPoE'};

    if ($VERSION <= 7.5) {
      $conf{PPPOE_MAC_START} = "00:1e:6b:03:00:01";
    }
    else {
      $conf{PPPOE_MAC_START} = "";
    }

    if ($DiversifEyeType eq "TeraVM") { # Force TeraVM to use adapter default.
       $conf{PPPOE_MAC_START} = "";
    }
    else {
       if (defined($thisKey->{'MAC_Start'})) {
         $conf{PPPOE_MAC_START} = $thisKey->{'MAC_Start'};
       }
    }

    if ($DiversifEyeType eq "8400") {
      $cardOffset = 2;
    }
    elsif ($DiversifEyeType eq "TeraVM") {
      $cardOffset = 9;
    }
    else {
      $cardOffset = 9;
    }
    if (defined $thisKey->{'diversifEye_User'}) {
      $conf{PPPOE_CARD} = $thisKey->{'diversifEye_User'} + $cardOffset;
    }
    else {
      $conf{PPPOE_CARD} = $diversifEyeUser + $cardOffset;
    }

    $conf{PPPOE_POOLED_PREFIX} = $PooledUePrefix;
    $conf{PPPOE_POOLED_UNIT} = "1";
    $conf{VLAN_TAG} = "";
    if ($DiversifEyeType eq "TeraVM") {
      $conf{PPPOE_PORT} = $portPrefix.$TeraVM_Client_IF;
      if ($OverrideVlanId > 0) {
         $conf{VLAN_TAG} = $OverrideVlanId;
      }
      else {
         $conf{VLAN_TAG} = $diversifEyeUser + 9;
      }
      if (defined $thisKey->{'VLAN_Tag'}) {
        if (($thisKey->{'VLAN_Tag'} > 0) && ($thisKey->{'VLAN_Tag'} < 4095)) {
          $conf{VLAN_TAG} = $thisKey->{'VLAN_Tag'};
        }
        elsif (($thisKey->{'VLAN_Tag'} eq "") || (lc($thisKey->{'VLAN_Tag'}) eq "none") || ($thisKey->{'VLAN_Tag'} == -1) || ($thisKey->{'VLAN_Tag'} == 0)) {
           if ($OverrideVlanId > 0) {
              printf(STDERR "Warning: VLANs are required in this configuration, using TM500 supplied VLAN Id: %s\n", $OverrideVlanId);
              $conf{VLAN_TAG} = $OverrideVlanId;
           }
           else {
              $conf{VLAN_TAG} = "";
           }
        }
      }
    }
    else {
        $conf{PPPOE_PORT} = $portPrefix."0";
        if (defined $thisKey->{'diversifEye_Port'}) {
            $conf{PPPOE_PORT} = $portPrefix.$thisKey->{'diversifEye_Port'};
        }
    }

    if (defined $thisKey->{'PAP_Authentication'}) {
      $conf{PPPOE_PAP} = $thisKey->{'PAP_Authentication'};
    }
    else {
      $conf{PPPOE_PAP} = 'false';
    }
    if (defined $thisKey->{'CHAP_Authentication'}) {
      $conf{PPPOE_CHAP} = $thisKey->{'CHAP_Authentication'};
    }
    else {
      $conf{PPPOE_CHAP} = 'false';
    }
    if (defined $thisKey->{'MTU'}) {
      $conf{PPPOE_MTU} = $thisKey->{'MTU'};
    }
    else {
      $conf{PPPOE_MTU} = 1492;
    }

    if (defined $thisKey->{'Create_Default_PPPoE_Client'}) {
      if (lc($thisKey->{'Create_Default_PPPoE_Client'}) eq "true") {
        $CreateDefaultPPPoEConnection = 1;
      }
    }

    $PPPoEIPv6UeRange = "";
    $PPPoEIPv6PdnRange = "";
    $PPPoEIPv6Enabled = 0;

    if (defined $thisKey->{'IPv6_PPPoE_Client'}) {
      $PPPoEIPv6Enabled = 1;

      if (defined $thisKey->{'IPv6_PPPoE_Client'}->{'UE'}) {
        $PPPoEIPv6UeRange = $thisKey->{'IPv6_PPPoE_Client'}->{'UE'};
      }
      if (defined $thisKey->{'IPv6_PPPoE_Client'}->{'PDN'}) {
        $PPPoEIPv6PdnRange = $thisKey->{'IPv6_PPPoE_Client'}->{'PDN'};
      }

      if (defined $thisKey->{'IPv6_PPPoE_Client'}->{'ENABLED'}) {
        if (lc($thisKey->{'IPv6_PPPoE_Client'}->{'ENABLED'}) eq "false") {
          $PPPoEIPv6UeRange = "";
          $PPPoEIPv6PdnRange = "";
          $PPPoEIPv6Enabled = 0;
        }
      }
    }
  }


  if (defined $rootKey->{'Application_Configuration'}->{'Client_Profiles'} ) {
    $ClientProfilesKey = $rootKey->{'Application_Configuration'}->{'Client_Profiles'};
  }
  else {
    printf(STDERR "%s\n", "error: Client profiles are not defined");
    exit 1;
  }

  $FtpPutEnabled = 0;
  $FtpGetEnabled = 0;
  $HttpEnabled = 0;
  $VoipEnabled = 0;
  $RtspEnabled = 0;
  $TwampEnabled = 0;
  $CpingEnabled = 0;
  $SpingEnabled = 0;
  $TeraFlowEnabled = 0;
  $IgmpEnabled = 0;
  $MldEnabled = 0;

  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $profileName = "Default";
      $suffix = "";
    }
    else {
      $profileName = "Profile_$profileId";
      $suffix = "_P$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'FTP_Put'}) {
        $FtpPutEnabled = 1;
      }

      if (defined $loadProfilesKey->{'FTP_Get'}) {
        $FtpGetEnabled = 1;
      }

      if (defined $loadProfilesKey->{'HTTP'}) {
        $HttpEnabled = 1;
        # Scan children for TLS Enabled.
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
        }

        foreach (@{$thisKey}) {
          if (defined $thisKey->[$i]->{'Use_TLS'}) {
            if (lc($thisKey->[$i]->{'Use_TLS'}) eq "true") {
              $HttpTlsSupportNeeded = 1;
            }
          }
          $i += 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIP'}) {
        $VoipEnabled = 1;
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $VoipEnabled = 1;
      }

      if (defined $loadProfilesKey->{'RTSP'}) {
        $RtspEnabled = 1;
      }

      if (defined $loadProfilesKey->{'TWAMP'}) {
        $TwampEnabled = 1;
      }

      if (defined $loadProfilesKey->{'cPing'}) {
        $CpingEnabled = 1;
      }

      if (defined $loadProfilesKey->{'sPing'}) {
        $SpingEnabled = 1;
      }

      if (defined $loadProfilesKey->{'TeraFlow'}) {
        $TeraFlowEnabled = 1;
      }

      if (defined $loadProfilesKey->{'IGMP'}) {
        $IgmpEnabled = 1;

      }

      if (defined $loadProfilesKey->{'MLD'}) {
        $MldEnabled = 1;
      }

    }
  }

};

if ($@) {
  printf(STDERR "%s\n", "error: Main config XML parsing problem: $@");
  exit 1;
}

for ($i = 0; $i <= 99; $i++) {
  $mac_addr = 'Ma'.$i;
  $Ma{$mac_addr} = "";
}

if (defined $rootKey->{'Network_Configuration'}) {
  $thisKey = $rootKey->{'Network_Configuration'};
  if (defined $thisKey->{'Flow_Processors'}) {
    for ($i = 0; $i <= 99; $i++) {
      $mac_addr = 'Ma'.$i;
      if (defined $thisKey->{'Flow_Processors'}->{$mac_addr}) {
        if (isMacObj($thisKey->{'Flow_Processors'}->{$mac_addr})) {
          $Ma{$mac_addr} = diversifEye::Mac->new("$thisKey->{'Flow_Processors'}->{$mac_addr}");
        }
      }

    }
  }
}

my $createServerEntry = 0;
my $createCoreGW = 0;
my @GatewayNames = ();

$FtpServerEnabled = 0;
$HttpServerEnabled = 0;
$VoipServerEnabled = 0;
$RtspServerEnabled = 0;
$TwampServerEnabled = 0;
$TeraFlowServerEnabled = 0;
$IgmpServerEnabled = 0;
$MldServerEnabled = 0;
$PingServerEnabled = 0;

eval {
  if (defined $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Server'}) {
    $rootKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Server'};

    $i = 0;
    $j = 0;
    if (!($rootKey =~ /ARRAY/)) {
      $rootKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Server'}];
    }

    foreach (@{$rootKey}) {
      $createServerEntry = 0;
      if (defined $rootKey->[$i]->{'Application'}) {
        if ($rootKey->[$i]->{'Application'} eq "FTP") {
          $createServerEntry = 1;
          $FtpServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "HTTP") {
          $createServerEntry = 1;
          $HttpServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "VoIP") {
          $createServerEntry = 1;
          $VoipServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "VoIMS") {
          $createServerEntry = 1;
          $VoipServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "RTSP") {
          $createServerEntry = 1;
          $RtspServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "TWAMP") {
          $createServerEntry = 1;
          $TwampServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "PING") {
          $createServerEntry = 1;
          $PingServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "TeraFlow") {
          $createServerEntry = 1;
          $TeraFlowServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "IGMP") {
          $createServerEntry = 1;
          $IgmpServerEnabled = 1;
        }
        elsif ($rootKey->[$i]->{'Application'} eq "MLD") {
          $createServerEntry = 1;
          $MldServerEnabled = 1;
        }
      }

      if ($createServerEntry) {

        $thisServerType = "";
        $thisGatewayName = "";
        $thisGatewayIp = "";
        if (($rootKey->[$i]->{'Type'} eq "External") || ($rootKey->[$i]->{'Type'} eq "Internal")) {
          $thisServerType = $rootKey->[$i]->{'Type'};
        }

        if (defined $rootKey->[$i]->{'Gateway_IP'}) {
          $thisGatewayIp = $rootKey->[$i]->{'Gateway_IP'};
          $thisIpVersion = $rootKey->[$i]->{'Ip_Version'};
          if ($thisGatewayIp ne "") {
            if (($thisIpVersion eq "6") && (index($thisGatewayIp, ":") == -1)) {
              $thisIpVersion = "4";
            }
            elsif (($thisIpVersion eq "4") && (index($thisGatewayIp, ":") != -1)) {
              $thisIpVersion = "6";
            }
          }

          $thisGatewayName = "gw_".$rootKey->[$i]->{'Gateway_IP'}."_v".$thisIpVersion;
          $thisGatewayName =~ s/\./_/g;
        }

        if ($DiversifEyeType eq "8400") {
          $cardOffset = 2;
        }
        elsif ($DiversifEyeType eq "TeraVM") {
          $cardOffset = 19;  # Server offset for TeraVM
        }
        else {
          $cardOffset = 9;
        }

        # Core Edge is only allowed on the 500 and 1000 products.
        if ((defined $rootKey->[$i]->{'Physical_Location'}) && (($DiversifEyeType eq "500" || $DiversifEyeType eq "1000")) && ($CORE_EDGE_ENABLED eq 1)) {
          if (lc($rootKey->[$i]->{'Physical_Location'}) eq "core") {
            $cardOffset = 19;
            $thisServerType = "Internal";

            $thisIpVersion = $rootKey->[$i]->{'Ip_Version'};
            if (defined $rootKey->[$i]->{'IP_Address'}) {
              if ($rootKey->[$i]->{'IP_Address'} ne "") {
                if (($thisIpVersion eq "6") && (index($rootKey->[$i]->{'IP_Address'}, ":") == -1)) {
                  $thisIpVersion = "4";
                }
                elsif (($thisIpVersion eq "4") && (index($rootKey->[$i]->{'IP_Address'}, ":") != -1)) {
                  $thisIpVersion = "6";
                }
              }
            }

            $thisGatewayName = "v".$thisIpVersion."_Core_GW";

            if ($createCoreGW == 0) {  # Only create one Core GW
              if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
              }
              elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
              }
              else {
                $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
              }

              $hconf[$j]{VLAN_TAG} = "";
              if ($DiversifEyeType eq "TeraVM") {
                $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
                if (defined $thisKey->{'VLAN_Tag'}) {
                  if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
                    $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
                  }
                  elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
                    $hconf[$j]{VLAN_TAG} = "";
                  }
                }
              }
              else {
                $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
              }

              $hconf[$j]{Type} = "v4_EHost";
              $hconf[$j]{HostName} = "v4_Core_GW";
              $hconf[$j]{Application} = "Gateway";

              $hconf[$j]{Number} = 1;
              $hconf[$j]{Outer} = "";
              $hconf[$j]{OP} = "";
              $hconf[$j]{Inner} = "";
              $hconf[$j]{IP} = "";
              $hconf[$j]{Addr} = "";
              $hconf[$j]{Rate} = "";
              $hconf[$j]{Active} = "";
              $hconf[$j]{Inactive} = "";
              $hconf[$j]{Location} = "Core";
              $hconf[$j]{ServerIp} = "";
              $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
              $hconf[$j]{PooledUnit} = "1";
              if ($VERSION >= 12.0) {
                if ((grep /^$hconf[$j]{Card}/,@PARTITION_INTERFACES) == 0) {
                  push(@PARTITION_INTERFACES, $hconf[$j]{Card});
                }
              }
              $j += 1;

              # IPv6 Core GW
              if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
              }
              elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
              }
              else {
                $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
              }

              $hconf[$j]{VLAN_TAG} = "";
              if ($DiversifEyeType eq "TeraVM") {
                $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
                if (defined $thisKey->{'VLAN_Tag'}) {
                  if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
                    $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
                  }
                  elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
                    $hconf[$j]{VLAN_TAG} = "";
                  }
                }
              }
              else {
                $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
              }

              $hconf[$j]{Type} = "v6_EHost";
              $hconf[$j]{HostName} = "v6_Core_GW";
              $hconf[$j]{Application} = "Gateway";

              $hconf[$j]{Number} = 1;
              $hconf[$j]{Outer} = "";
              $hconf[$j]{OP} = "";
              $hconf[$j]{Inner} = "";
              $hconf[$j]{IP} = "";
              $hconf[$j]{Addr} = "";
              $hconf[$j]{Rate} = "";
              $hconf[$j]{Active} = "";
              $hconf[$j]{Inactive} = "";
              $hconf[$j]{Location} = "Core";
              $hconf[$j]{ServerIp} = "";
              $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
              $hconf[$j]{PooledUnit} = "1";
              if ($VERSION >= 12.0) {
                if ((grep /^$hconf[$j]{Card}/,@PARTITION_INTERFACES) == 0) {
                  push(@PARTITION_INTERFACES, $hconf[$j]{Card});
                }
              }
              $j += 1;

            }

            $createCoreGW += 1;
          }
        }
        elsif ($thisGatewayName ne "") {

            if ((grep /^$thisGatewayName/,@GatewayNames) == 0) {
              push(@GatewayNames, $thisGatewayName);

              if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
              }
              elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
              }
              else {
                $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
              }

              $thisIpVersion = $rootKey->[$i]->{'Ip_Version'};
              if ($thisGatewayIp ne "") {
                if (($thisIpVersion eq "6") && (index($thisGatewayIp, ":") == -1)) {
                  $thisIpVersion = "4";
                }
                elsif (($thisIpVersion eq "4") && (index($thisGatewayIp, ":") != -1)) {
                  $thisIpVersion = "6";
                }
              }

              $hconf[$j]{VLAN_TAG} = "";
              if ($DiversifEyeType eq "TeraVM") {
                $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
                if (defined $thisKey->{'VLAN_Tag'}) {
                  if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
                    $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
                  }
                  elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
                    $hconf[$j]{VLAN_TAG} = "";
                  }
                }
              }
              else {
                $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
              }

              $hconf[$j]{Type} = "v".$thisIpVersion."_EHost";
              $hconf[$j]{HostName} = $thisGatewayName;
              $hconf[$j]{Application} = "Gateway";

              $hconf[$j]{Number} = 1;
              $hconf[$j]{Outer} = "";
              $hconf[$j]{OP} = "";
              $hconf[$j]{Inner} = "";
              $hconf[$j]{IP} = $thisGatewayIp;
              $hconf[$j]{Addr} = "";
              $hconf[$j]{Rate} = "";
              $hconf[$j]{Active} = "";
              $hconf[$j]{Inactive} = "";
              $hconf[$j]{Location} = "Edge";
              $hconf[$j]{ServerIp} = "";
              $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
              $hconf[$j]{PooledUnit} = "1";
              if ($VERSION >= 12.0) {
                if ((grep /^$hconf[$j]{Card}/,@PARTITION_INTERFACES) == 0) {
                  push(@PARTITION_INTERFACES, $hconf[$j]{Card});
                }
              }
              $j += 1;
            }
        }
        elsif ($thisGatewayName eq "") {
          if ((grep /^$defaultGatewayName/,@GatewayNames) == 0) {
            push(@GatewayNames, $defaultGatewayName);

            if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
              $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
            }
            elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
              $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
            }
            else {
              $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
            }

            $hconf[$j]{VLAN_TAG} = "";
            if ($DiversifEyeType eq "TeraVM") {
              $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
              if (defined $thisKey->{'VLAN_Tag'}) {
                if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
                  $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
                }
                elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
                  $hconf[$j]{VLAN_TAG} = "";
                }
              }
            }
            else {
              $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
            }

            $hconf[$j]{Type} = "v4_EHost";
            $hconf[$j]{HostName} = $defaultGatewayName;
            $hconf[$j]{Application} = "Gateway";

            $hconf[$j]{Number} = 1;
            $hconf[$j]{Outer} = "";
            $hconf[$j]{OP} = "";
            $hconf[$j]{Inner} = "";
            $hconf[$j]{IP} = $conf{Gateway_ip};
            $hconf[$j]{Addr} = "";
            $hconf[$j]{Rate} = "";
            $hconf[$j]{Active} = "";
            $hconf[$j]{Inactive} = "";
            $hconf[$j]{Location} = "Edge";
            $hconf[$j]{ServerIp} = "";
            $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
            $hconf[$j]{PooledUnit} = "1";
            if ($VERSION >= 12.0) {
              if ((grep /^$hconf[$j]{Card}/,@PARTITION_INTERFACES) == 0) {
                push(@PARTITION_INTERFACES, $hconf[$j]{Card});
              }
            }
            $j += 1;

            if ((grep /^$defaultIPv6GatewayName/,@GatewayNames) == 0) {
              push(@GatewayNames, $defaultIPv6GatewayName);

              if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
              }
              elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
                $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
              }
              else {
                $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
              }

              $hconf[$j]{VLAN_TAG} = "";
              if ($DiversifEyeType eq "TeraVM") {
                $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
                if (defined $thisKey->{'VLAN_Tag'}) {
                  if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
                    $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
                  }
                  elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
                    $hconf[$j]{VLAN_TAG} = "";
                  }
                }
              }
              else {
                $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
              }

              $hconf[$j]{Type} = "v6_EHost";
              $hconf[$j]{HostName} = $defaultIPv6GatewayName;
              $hconf[$j]{Application} = "Gateway";

              $hconf[$j]{Number} = 1;
              $hconf[$j]{Outer} = "";
              $hconf[$j]{OP} = "";
              $hconf[$j]{Inner} = "";
              $hconf[$j]{IP} = $conf{v6_Gateway_ip};
              $hconf[$j]{Addr} = "";
              $hconf[$j]{Rate} = "";
              $hconf[$j]{Active} = "";
              $hconf[$j]{Inactive} = "";
              $hconf[$j]{Location} = "Edge";
              $hconf[$j]{ServerIp} = "";
              $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
              $hconf[$j]{PooledUnit} = "1";

              $j += 1;
            }
          }
        }

        if (defined $rootKey->[$i]->{'diversifEye_Card'}) {
          $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_Card'};
        }
        elsif (defined $rootKey->[$i]->{'diversifEye_User'}) {
          $hconf[$j]{Card} = $rootKey->[$i]->{'diversifEye_User'} + $cardOffset;
        }
        else {
          $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;
        }

        $hconf[$j]{VLAN_TAG} = "";
        if ($DiversifEyeType eq "TeraVM") {
          $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
          if (defined $rootKey->[$i]->{'VLAN_Tag'}) {
            if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
              $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
            }
            elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
              $hconf[$j]{VLAN_TAG} = "";
            }
          }
        }
        else {
          $hconf[$j]{Port} = $portPrefix.$rootKey->[$i]->{'diversifEye_Port'};
        }

        $hconf[$j]{ServerIp} = "";
        $thisHostName = $rootKey->[$i]->{'Host_Name'};
        $hconf[$j]{HostName} = $thisHostName;

        if ((grep /^$thisHostName/,@ServerNames) == 0) {
          push(@ServerNames, $thisHostName);
        }


        $thisIpVersion = $rootKey->[$i]->{'Ip_Version'};
        if (defined $rootKey->[$i]->{'IP_Address'}) {
          if ($rootKey->[$i]->{'IP_Address'} ne "") {
            if (($thisIpVersion eq "6") && (index($rootKey->[$i]->{'IP_Address'}, ":") == -1)) {
              $thisIpVersion = "4";
            }
            elsif (($thisIpVersion eq "4") && (index($rootKey->[$i]->{'IP_Address'}, ":") != -1)) {
              $thisIpVersion = "6";
            }
          }
        }

        if (($thisServerType eq "External") && ($rootKey->[$i]->{'Application'} ne "PING")) {  # PING can only be internal.
          $hconf[$j]{Type} = "v".$thisIpVersion."_EServer";
        }
        elsif ($thisServerType eq "Internal") {

          if (defined $rootKey->[$i]->{'IP_Address'}) {
            if ($rootKey->[$i]->{'IP_Address'} ne "") {
              $hconf[$j]{ServerIp} = $rootKey->[$i]->{'IP_Address'};
              $serverHosts{$thisHostName} = $hconf[$j]{ServerIp};
              $serverHosts{$thisHostName} =~ s/:/-/g;
            }
          }

          $thisIpVersion = $rootKey->[$i]->{'Ip_Version'};
          if ($hconf[$j]{ServerIp} ne "") {
            if (($thisIpVersion eq "6") && (index($hconf[$j]{ServerIp}, ":") == -1)) {
              $thisIpVersion = "4";
            }
            elsif (($thisIpVersion eq "4") && (index($hconf[$j]{ServerIp}, ":") != -1)) {
              $thisIpVersion = "6";
            }
          }

          $hconf[$j]{Type} = "v".$thisIpVersion."_DVHS";
          if ($thisGatewayName eq "") {
            if ($thisIpVersion eq "6") {
              $thisGatewayName = $defaultIPv6GatewayName;
            }
            else {
              $thisGatewayName = $defaultGatewayName;
            }
          }
        }
        else {
          $hconf[$j]{Type} = "";
        }

        $hconf[$j]{GatewayName} = $thisGatewayName;

        # Look for the client src ports, dst ports and multicast address.  Payload size, data rate.
        $hconf[$j]{ServerPorts} = "";
        if ($rootKey->[$i]->{'Application'} eq "IGMP") {
          for ($profileId = -1; $profileId <= 9; $profileId++) {
            if ($profileId == -1) {
              $profileName = "Default";
              $suffix = "";
            }
            else {
              $profileName = "Profile_$profileId";
              $suffix = "_P$profileId";
            }

            if (defined $ClientProfilesKey->{$profileName} ) {
              $loadProfilesKey = $ClientProfilesKey->{$profileName};

              if (defined $loadProfilesKey->{'IGMP'}) {
                # Scan children for IGMP paramters.
                $thisKey = ();
                $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'};
                $thisKeyIndex = 0;

                if (!($thisKey =~ /ARRAY/)) {
                  $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'}];
                }

                $hconf[$j]{MultiCastAddr} = "";
                $hconf[$j]{SrcPort} = "";
                $hconf[$j]{DstPort} = "";
                $hconf[$j]{MediaType} = "RTP";  # <!-- RTP, MPEG2-TS/RTP, MPEG2-TS-->
                $hconf[$j]{PayloadSize} = 1316;
                $hconf[$j]{DataRate} = 1;

                foreach (@{$thisKey}) {
                  if (($thisKey->[$thisKeyIndex]->{'Server_Host_Name'} eq $hconf[$j]{HostName})) {

                    if (defined $thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'}) {
                      if ($thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'} ne "") {
                        $hconf[$j]{MultiCastAddr} = $thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Source_Port'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Source_Port'} ne "") && ($thisKey->[$thisKeyIndex]->{'Source_Port'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Source_Port'} <= 65535)) {
                        $hconf[$j]{SrcPort} = $thisKey->[$thisKeyIndex]->{'Source_Port'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Destination_Port'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Destination_Port'} ne "") && ($thisKey->[$thisKeyIndex]->{'Destination_Port'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Destination_Port'} <= 65535)) {
                        $hconf[$j]{DstPort} = $thisKey->[$thisKeyIndex]->{'Destination_Port'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Media_Transport'}) {
                      if ((uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "RTP") || (uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "MPEG2-TS") || (uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "MPEG2-TS/RTP")) {
                        $hconf[$j]{MediaType} = uc($thisKey->[$thisKeyIndex]->{'Media_Transport'});
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Payload_Size'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Payload_Size'} ne "") && ($thisKey->[$thisKeyIndex]->{'Payload_Size'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Payload_Size'} <= 1472)) {
                        $hconf[$j]{PayloadSize} = $thisKey->[$thisKeyIndex]->{'Payload_Size'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Data_Rate'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Data_Rate'} ne "") && ($thisKey->[$thisKeyIndex]->{'Data_Rate'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Data_Rate'} <= 200000)) {
                        $hconf[$j]{DataRate} = $thisKey->[$thisKeyIndex]->{'Data_Rate'};
                      }
                    }


                  }
                  $thisKeyIndex += 1;
                }
              }
            }
          }
        }

        # Look for the client src ports, dst ports and multicast address.  Payload size, data rate.
        $hconf[$j]{ServerPorts} = "";
        if ($rootKey->[$i]->{'Application'} eq "MLD") {
          for ($profileId = -1; $profileId <= 9; $profileId++) {
            if ($profileId == -1) {
              $profileName = "Default";
              $suffix = "";
            }
            else {
              $profileName = "Profile_$profileId";
              $suffix = "_P$profileId";
            }

            if (defined $ClientProfilesKey->{$profileName} ) {
              $loadProfilesKey = $ClientProfilesKey->{$profileName};

              if (defined $loadProfilesKey->{'MLD'}) {
                # Scan children for MLD paramters.
                $thisKey = ();
                $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'};
                $thisKeyIndex = 0;

                if (!($thisKey =~ /ARRAY/)) {
                  $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'}];
                }

                $hconf[$j]{MultiCastAddr} = "";
                $hconf[$j]{SrcPort} = "";
                $hconf[$j]{DstPort} = "";
                $hconf[$j]{MediaType} = "RTP";  # <!-- RTP, MPEG2-TS/RTP, MPEG2-TS-->
                $hconf[$j]{PayloadSize} = 1316;
                $hconf[$j]{DataRate} = 1;

                foreach (@{$thisKey}) {
                  if (($thisKey->[$thisKeyIndex]->{'Server_Host_Name'} eq $hconf[$j]{HostName})) {

                    if (defined $thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'}) {
                      if ($thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'} ne "") {
                        $hconf[$j]{MultiCastAddr} = $thisKey->[$thisKeyIndex]->{'Multicast_Group_Addrerss'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Source_Port'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Source_Port'} ne "") && ($thisKey->[$thisKeyIndex]->{'Source_Port'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Source_Port'} <= 65535)) {
                        $hconf[$j]{SrcPort} = $thisKey->[$thisKeyIndex]->{'Source_Port'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Destination_Port'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Destination_Port'} ne "") && ($thisKey->[$thisKeyIndex]->{'Destination_Port'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Destination_Port'} <= 65535)) {
                        $hconf[$j]{DstPort} = $thisKey->[$thisKeyIndex]->{'Destination_Port'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Media_Transport'}) {
                      if ((uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "RTP") || (uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "MPEG2-TS") || (uc($thisKey->[$thisKeyIndex]->{'Media_Transport'}) eq "MPEG2-TS/RTP")) {
                        $hconf[$j]{MediaType} = uc($thisKey->[$thisKeyIndex]->{'Media_Transport'});
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Payload_Size'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Payload_Size'} ne "") && ($thisKey->[$thisKeyIndex]->{'Payload_Size'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Payload_Size'} <= 1472)) {
                        $hconf[$j]{PayloadSize} = $thisKey->[$thisKeyIndex]->{'Payload_Size'};
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'Data_Rate'}) {
                      if (($thisKey->[$thisKeyIndex]->{'Data_Rate'} ne "") && ($thisKey->[$thisKeyIndex]->{'Data_Rate'} >= 1) && ($thisKey->[$thisKeyIndex]->{'Data_Rate'} <= 200000)) {
                        $hconf[$j]{DataRate} = $thisKey->[$thisKeyIndex]->{'Data_Rate'};
                      }
                    }


                  }
                  $thisKeyIndex += 1;
                }
              }
            }
          }
        }


        # Look for the client protocol and port for Teraflow
        $hconf[$j]{ServerPorts} = "";
        $hconf[$j]{Protocol} = "UDP";
        $hconf[$j]{TransportPort} = "5001";
        if ($rootKey->[$i]->{'Application'} eq "TeraFlow") {
          for ($profileId = -1; $profileId <= 9; $profileId++) {
            if ($profileId == -1) {
              $profileName = "Default";
              $suffix = "";
            }
            else {
              $profileName = "Profile_$profileId";
              $suffix = "_P$profileId";
            }

            if (defined $ClientProfilesKey->{$profileName} ) {
              $loadProfilesKey = $ClientProfilesKey->{$profileName};

              if (defined $loadProfilesKey->{'TeraFlow'}) {
                # Scan children for Teraflow protocol.
                $thisKey = ();
                $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'};
                $thisKeyIndex = 0;

                if (!($thisKey =~ /ARRAY/)) {
                  $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'}];
                }

                foreach (@{$thisKey}) {
                  if (($thisKey->[$thisKeyIndex]->{'Server_Host_Name'} eq $hconf[$j]{HostName})) {

                    if (defined $thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Type'}) {
                      if (lc($thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Type'}) eq "tcp") {
                        $hconf[$j]{Protocol} = "TCP";
                      }
                    }

                    if (defined $thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Port'}) {
                      if (($thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Port'} ne "") && ($thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Port'} >= 1) && ($thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Port'} <= 65535)) {
                        $hconf[$j]{TransportPort} = $thisKey->[$thisKeyIndex]->{'TeraFlow_Transport_Port'};
                      }
                    }

                  }
                  $thisKeyIndex += 1;
                }
              }
            }
          }
        }

        # Look for the client transport ports for SIP Transport Ports
        $hconf[$j]{ServerPorts} = "";
        $hconf[$j]{SIPDomain} = $defaultSIPDomain;
        if (($rootKey->[$i]->{'Application'} eq "VoIP") || ($rootKey->[$i]->{'Application'} eq "VoIMS")) {
          for ($profileId = -1; $profileId <= 9; $profileId++) {
            if ($profileId == -1) {
              $profileName = "Default";
              $suffix = "";
            }
            else {
              $profileName = "Profile_$profileId";
              $suffix = "_P$profileId";
            }

            if (defined $ClientProfilesKey->{$profileName} ) {
              $loadProfilesKey = $ClientProfilesKey->{$profileName};

              if ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) {
                # Scan children for Transport ports and add the SIP Server Domain.
                $thisKey = ();
                $nextKeyId = 0;
                $thisKeyIndex = 0;

                if (defined $loadProfilesKey->{'VoIP'}) {
                  $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
                  if (!($thisKey =~ /ARRAY/)) {
                     $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
                  }
                  foreach (@{$thisKey}) {
                    $nextKeyId = $nextKeyId + 1;
                  }
                }

                if (defined $loadProfilesKey->{'VoIMS'}) {
                  $thisVoimsKey = ();
                  $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
                  if (!($thisVoimsKey =~ /ARRAY/)) {
                    $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
                  }
                  $m = 0;
                  foreach (@{$thisVoimsKey}) {
                    $thisVoimsKey->[$m]->{'Alias'} = $defaultVoimsAlias;
                    $thisKey->[$nextKeyId] = $thisVoimsKey->[$m];
                    $m = $m + 1;
                    $nextKeyId = $nextKeyId + 1;
                  }
                }

                foreach (@{$thisKey}) {
                  if (defined $thisKey->[$thisKeyIndex]->{'SIP_Server'}) {
                    if (defined $thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'Server_Host_Name'}) {
                      if (($thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'Server_Host_Name'} eq $hconf[$j]{HostName})) {
                        if (defined $thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'Domain'}) {
                          $hconf[$j]{SIPDomain} = $thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'Domain'};
                        }
                      }

                      if (($thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'Server_Host_Name'} eq $hconf[$j]{HostName}) && ($doPerPortVoIPProxy eq 1)) {
                        if (defined $thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'SIP_Transport_Port'}) {
                          if (($thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'SIP_Transport_Port'} != $SIPTransportPort) && ($thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'SIP_Transport_Port'} ne "")) {
                            if ($hconf[$j]{ServerPorts} eq "") {
                              $hconf[$j]{ServerPorts} = $thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'SIP_Transport_Port'};
                            }
                            else {
                              $hconf[$j]{ServerPorts} = $hconf[$j]{ServerPorts}.",".$thisKey->[$thisKeyIndex]->{'SIP_Server'}->{'SIP_Transport_Port'};
                            }
                          }
                        }
                        else {
                          if (($hconf[$j]{ServerPorts} eq "") && (index($hconf[$j]{ServerPorts}, $SIPTransportPort) == -1)){
                            $hconf[$j]{ServerPorts} = $SIPTransportPort;
                          }
                          else {
                            $hconf[$j]{ServerPorts} = $hconf[$j]{ServerPorts}.",".$SIPTransportPort;
                          }
                        }
                      }
                    }
                  }
                  $thisKeyIndex += 1;
                }
                if ($hconf[$j]{ServerPorts} eq "") {
                  $hconf[$j]{ServerPorts} = $SIPTransportPort;  # Add the default port.
                }
              }
            }
          }
        }

        if ( ( ($rootKey->[$i]->{'Application'} eq "VoIP") || ($rootKey->[$i]->{'Application'} eq "VoIMS") ) && ($thisServerType eq "External") ) {
          $hconf[$j]{Application} = "ExternalSIPServer";
        }
        elsif ( ( ($rootKey->[$i]->{'Application'} eq "VoIP") || ($rootKey->[$i]->{'Application'} eq "VoIMS") ) && ($thisServerType eq "Internal") ) {
          $hconf[$j]{Application} = "SIPServer";
          if ((grep /^$hconf[$j]{HostName}."_voip"/,@InternalVoIPServerNames) == 0) {
            push(@InternalVoIPServerNames, $hconf[$j]{HostName}."_voip");
          }
        }

        elsif (($rootKey->[$i]->{'Application'} eq "TeraFlow") && ($thisServerType eq "Internal")) {
          $hconf[$j]{Application} = $rootKey->[$i]->{'Application'}."Server";
          if ((grep /^$hconf[$j]{HostName}."_voip"/,@InternalTFServerNames) == 0) {
            push(@InternalTFServerNames, $hconf[$j]{HostName}."_tf");
            if (defined($rootKey->[$i]->{'IP_Address'})) {
              if ($rootKey->[$i]->{'IP_Address'} ne "") {
                $InternalTFServerIp{$hconf[$j]{HostName}."_tf"} = $rootKey->[$i]->{'IP_Address'}
              }
            }
          }
        }

        elsif (($rootKey->[$i]->{'Application'} eq "IGMP") && ($thisServerType eq "Internal")) {
          $hconf[$j]{Application} = $rootKey->[$i]->{'Application'}."Server";
          if ((grep /^$hconf[$j]{HostName}."_igmp"/,@InternalIgmpServerNames) == 0) {
            push(@InternalIgmpServerNames, $hconf[$j]{HostName}."_igmp");
            if (defined($rootKey->[$i]->{'IP_Address'})) {
              if ($rootKey->[$i]->{'IP_Address'} ne "") {
                $InternalIgmpServerIp{$hconf[$j]{HostName}."_igmp"} = $rootKey->[$i]->{'IP_Address'}
              }
            }
          }
        }

        elsif (($rootKey->[$i]->{'Application'} eq "MLD") && ($thisServerType eq "Internal")) {
          $hconf[$j]{Application} = $rootKey->[$i]->{'Application'}."Server";
          if ((grep /^$hconf[$j]{HostName}."_mld"/,@InternalMldServerNames) == 0) {
            push(@InternalMldServerNames, $hconf[$j]{HostName}."_mld");
            if (defined($rootKey->[$i]->{'IP_Address'})) {
              if ($rootKey->[$i]->{'IP_Address'} ne "") {
                $InternalMldServerIp{$hconf[$j]{HostName}."_mld"} = $rootKey->[$i]->{'IP_Address'}
              }
            }
          }
        }

        elsif ($rootKey->[$i]->{'Application'} eq "PING") {
          $hconf[$j]{Application} = $rootKey->[$i]->{'Application'};
        }
        else {
          $hconf[$j]{Application} = $rootKey->[$i]->{'Application'}."Server";
        }

        if (defined($rootKey->[$i]->{'IP_Address'})) {
          if ($rootKey->[$i]->{'IP_Address'} ne "") {
            $serverHosts{$thisHostName} = $rootKey->[$i]->{'IP_Address'};
          }
        }

        $hconf[$j]{Number} = 1;
        $hconf[$j]{Outer} = "";
        $hconf[$j]{OP} = "";
        $hconf[$j]{Inner} = "";
        $hconf[$j]{IP} = "";
        $hconf[$j]{Addr} = $rootKey->[$i]->{'IP_Address'};
        $hconf[$j]{Rate} = "";
        $hconf[$j]{Active} = "";
        $hconf[$j]{Inactive} = "";
        $hconf[$j]{Location} = "Edge";
        $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
        $hconf[$j]{PooledUnit} = "1";
        if (defined $rootKey->[$i]->{'Physical_Location'}) {
          if (lc($rootKey->[$i]->{'Physical_Location'}) eq "core") {
            $hconf[$j]{Location} = "Core";
          }
        }

        if (defined $rootKey->[$i]->{'IP_Address'}) {
          if ($rootKey->[$i]->{'IP_Address'} ne "") {
            $hconf[$j]{ServerIp} = $rootKey->[$i]->{'IP_Address'};
          }
        }

        $j += 1;
        $i += 1;

      }
    }
  }
};

## Create the default PPPoE if it has been requested.
if ($CreateDefaultPPPoEConnection) {
      if ($DiversifEyeType eq "8400") {
        $cardOffset = 2;
      }
      elsif ($DiversifEyeType eq "TeraVM") {
        $cardOffset = 9;
      }
      else {
        $cardOffset = 9;
      }
      $hconf[$j]{Card} = $diversifEyeUser + $cardOffset;

      $hconf[$j]{VLAN_TAG} = "";
      if ($DiversifEyeType eq "TeraVM") {
        $hconf[$j]{Port} = $portPrefix.$TeraVM_Server_IF;
        if (defined $rootKey->[$i]->{'VLAN_Tag'}) {
          if (($rootKey->[$i]->{'VLAN_Tag'} >= 0) && ($rootKey->[$i]->{'VLAN_Tag'} <= 4095)) {
            $hconf[$j]{VLAN_TAG} = $rootKey->[$i]->{'VLAN_Tag'};
          }
          elsif (($rootKey->{'VLAN_Tag'} eq "") || (lc($rootKey->{'VLAN_Tag'}) eq "none") || ($rootKey->{'VLAN_Tag'} == -1)) {
            $hconf[$j]{VLAN_TAG} = "";
          }
        }
      }
      else {
        $hconf[$j]{Port} = $portPrefix."0";
      }

      $hconf[$j]{Type} = 'v4_DVH';
      $hconf[$j]{HostName} = 'pppoe_default';
      $hconf[$j]{GatewayName} = '';
      $hconf[$j]{Application} = '';
      $hconf[$j]{Number} = 1;
      $hconf[$j]{Outer} = '';
      $hconf[$j]{OP} = 0;
      $hconf[$j]{Inner} = 0;
      $hconf[$j]{IP} = 50;
      $hconf[$j]{Addr} = 500;
      $hconf[$j]{Rate} = 200;
      $hconf[$j]{Active} = '';
      $hconf[$j]{Inactive} = '';
      $hconf[$j]{Location} = "Edge";
      $hconf[$j]{PooledPrefix} = $PooledSgiPrefix;
      $hconf[$j]{PooledUnit} = "1";
}

if ($@) {
  printf(STDERR "%s\n", "error: XML parsing problem with application section: $@");
  exit 1;
}

if (($FtpPutEnabled eq 1) && ($FtpServerEnabled eq 0)) {
  $FtpPutEnabled = 0;
}

if (($FtpGetEnabled eq 1) && ($FtpServerEnabled eq 0)) {
  $FtpGetEnabled = 0;
}

if (($HttpEnabled eq 1) && ($HttpServerEnabled eq 0)) {
  $HttpEnabled = 0;
}

if (($VoipEnabled eq 1) && ($VoipServerEnabled eq 0)) {
  $VoipEnabled = 0;
}

if (($RtspEnabled eq 1) && ($RtspServerEnabled eq 0)) {
  $RtspEnabled = 0;
}

if (($TwampEnabled eq 1) && ($TwampServerEnabled eq 0)) {
  $TwampEnabled = 0;
}

if (($SpingEnabled eq 1) && ($PingServerEnabled eq 0)) {
  $SpingEnabled = 0;
}

if (($TeraFlowEnabled eq 1) && ($TeraFlowServerEnabled eq 0)) {
  $TeraFlowEnabled = 0;
}

if (($IgmpEnabled eq 1) && ($IgmpServerEnabled eq 0)) {
  $IgmpEnabled = 0;
}

if (($MldEnabled eq 1) && ($MldServerEnabled eq 0)) {
  $MldEnabled = 0;
}

## Generating the diversifEye Configuration

my $Server_ip = diversifEye::IpAddress->new("$conf{Server_ip}"."/".$MaskBits);
my $Client_ip = diversifEye::IpAddress->new("$conf{Client_ip}"."/".$ClientBits);
my $Gateway_ip = diversifEye::IpAddress->new("$conf{Gateway_ip}"."/".$ClientBits);
my $v4_Client_GW_ip = diversifEye::IpAddress->new("$conf{Client_GW_ip}"."/".$ClientBits);
my $v4_Core_GW_ip = diversifEye::IpAddress->new("$conf{Core_GW_ip}"."/".$ClientBits);
my $Client_subnet_ip = diversifEye::IpAddress->new("$conf{Client_subnet_ip}"."/".$ClientBits);
my $Client_ip_batch_start_addr = diversifEye::IpAddress->new("$conf{Client_ip_batch_start_addr}"."/".$ClientBits);
my $v6_Server_ip = diversifEye::IpAddress->new("$conf{v6_Server_ip}"."/".$v6_MaskBits);
my $v6_Client_ip = diversifEye::IpAddress->new("$conf{v6_Client_ip}"."/".$v6_MaskBits);
my $v6_Client_GW_ip = diversifEye::IpAddress->new("$conf{v6_Client_GW_ip}"."/".$v6_MaskBits);
my $v6_Core_GW_ip = diversifEye::IpAddress->new("$conf{v6_Core_GW_ip}"."/".$v6_MaskBits);
my $v6_Gateway_ip = diversifEye::IpAddress->new("$conf{v6_Gateway_ip}"."/".$v6_MaskBits);

## TM500 Specific
my $UEs = $conf{UEs};
my $PDNs_per_UE = $conf{PDNs_per_UE};
my $service_name_prefix = "tm500_lte_" . $conf{TM500_LAN_IP} . "_";
if ($OverridePppoePrefix ne "") {
   $service_name_prefix = $OverridePppoePrefix . "_";
}
else {
   if ($RatType eq "UMTS") {
     $service_name_prefix = "tm500_umts_" . $conf{TM500_LAN_IP} . "_";
   }
   elsif ($RatType eq "MULTI") {
     $service_name_prefix = "tm500_" . $conf{TM500_LAN_IP} . "_";
   }
}

## Create the resouce lists per Profile....

my $Hrl;
my $Bpl;
my $Bp;
my $Fgcl;
my $Fpcl;
my $Srl;
my $Frl;
my $Rtsp;
my $Pe;
my $Tz;
my $vcl;
my $Vcl;
my $Rrl;
my $Rsp;
my $Tts;
my $Dag;
my $Pfn;
my $Brll;
my $Brlcl;

printf(STDERR "Configuration Parsed, Starting to Generate Test Group: %s, RAT Type: %s, Using Reduce: %s, Using Scaled Entities: %s, diversifEye version: %s, chassis type: %s ...\n", $conf{TestGroupName}, $RatType, $ReduceOnOff, $useScaledEntities, $diversifEye::TestGroup::VERSION, $DiversifEyeType);

$TotalHosts = $TotalPPPoEHosts + $TotalAppHosts;
$TotalEntities = $TotalHosts + $TotalApps;
#printf(STDERR "Total Hosts: %s (%s UE, %s SGI), Total Apps: %s, Total Entities: %s\n", $TotalHosts, $TotalPPPoEHosts, $TotalAppHosts, $TotalApps, $TotalEntities);

$conf{InterfaceSelectionMode} = "Classic Mode";
if ($PooledConfig == 1) {
    $conf{InterfaceSelectionMode} = "Pool Manager Mode";
}

my $Tg;
if ($VERSION >= 12) {
  $Tg = diversifEye::TestGroup->new(LowMemory=>$Clo->{LowMemory}, Reduce=>$ReduceOnOff, type=>'IP', name=>$conf{TestGroupName}, description=>$conf{TestGroupDesc}, interface_selection_mode=>$conf{InterfaceSelectionMode});
}
else {
  $Tg = diversifEye::TestGroup->new(LowMemory=>$Clo->{LowMemory}, Reduce=>$ReduceOnOff, type=>'IP', name=>$conf{TestGroupName}, description=>$conf{TestGroupDesc});
}

if ($RtspEnabled eq 1) {
  $Tg->Add(diversifEye::Profile->new(name=>$RtspPortProfileDefault, profile_distribution_function=>"16384-32767:1"));
}
$Tg->Add(diversifEye::Profile->new(name=>$RtpPortProfileDefault, profile_distribution_function=>"32768-49151:1"));
$Tg->Add(diversifEye::Profile->new(name=>$VoipPortProfileDefault, profile_distribution_function=>"49152-65533:1"));
$Tg->Add(diversifEye::Profile->new(name=>$SilenceProfileDefault, profile_distribution_function=>"10000-20000:1"));

## Create rtsp port profiles
printf(STDERR "%s\n", 'Generating RTSP Port Profiles ...');
@PortProfileNames = ();

for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $profileName = "Default";
      $suffix = "";
    }
    else {
      $profileName = "Profile_$profileId";
      $suffix = "_P$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
        $thisKey = ();
        $nextKeyId = 0;

        if (defined $loadProfilesKey->{'VoIP'}) {
          $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
          if (!($thisKey =~ /ARRAY/)) {
            $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
          }
          foreach (@{$thisKey}) {
            $nextKeyId = $nextKeyId + 1;
          }
        }

        if (defined $loadProfilesKey->{'VoIMS'}) {
          $thisVoimsKey = ();
          $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
          if (!($thisVoimsKey =~ /ARRAY/)) {
            $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
          }
          $i = 0;
          foreach (@{$thisVoimsKey}) {
            $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
            $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
            $i = $i + 1;
            $nextKeyId = $nextKeyId + 1;
          }
        }
        $i = 0;

        foreach (@{$thisKey}) {
          if (defined $thisKey->[$i]->{'Rtp_Port'}) {
                    $thisMediaPorts = $thisKey->[$i]->{'Rtp_Port'};
                    $thisMediaPorts =~ s/\.\./-/g;  # change .. to -
                    if ($thisMediaPorts =~ m/\-/) {
                      $mediaPortsName = "Voip_".$thisMediaPorts;
                      if ((grep /^$mediaPortsName/,@PortProfileNames) == 0) {
                        push(@PortProfileNames, $mediaPortsName);
                        $Tg->Add(diversifEye::Profile->new(name=>$mediaPortsName, profile_distribution_function=>$thisMediaPorts.":1"));
                      }
          }
          $i += 1;
        }
        }
      }

      if (defined $loadProfilesKey->{'RTSP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
        }

        foreach (@{$thisKey}) {
          if (defined $thisKey->[$i]->{'Media_Port'}) {
                    $thisMediaPorts = $thisKey->[$i]->{'Media_Port'};
                    $thisMediaPorts =~ s/\.\./-/g;  # change .. to -
                    if ($thisMediaPorts =~ m/\-/) {
                      $mediaPortsName = "Rtsp_".$thisMediaPorts;
                      if ((grep /^$mediaPortsName/,@PortProfileNames) == 0) {
                        push(@PortProfileNames, $mediaPortsName);
                        $Tg->Add(diversifEye::Profile->new(name=>$mediaPortsName, profile_distribution_function=>$thisMediaPorts.":1"));
                      }
          }
          $i += 1;
        }
      }

    }
  }
}


### TCP Characteristics
printf(STDERR "%s\n", 'Generating TCP Characteristics ...');

$Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsDefault, tcp_profile_max_transmit_buffer_size=>$conf{TCPMaxTransmitBufferSize}, tcp_profile_max_advert_recv_window_size=>$conf{TCPMaxAdvertisedReceivedWindowSize}, tcp_window_scale=>$conf{TCPWindowScale},  tcp_profile_use_sack_when_permitted=>$conf{TCPUseSACKWhenPermitted}, tcp_profile_set_sack_permitted=>$conf{TCPSetSACKPermitted}, tcp_supp_timestamp_when_req=>$conf{TCPSupportTimestampWhenRequested}, tcp_req_timestamp=>$conf{TCPRequestTimestamp}));

@FtpGetAliasNames = ();
@FtpPutAliasNames = ();
@HttpAliasNames = ();
@RtspAliasNames = ();
@TwampAliasNames = ();
@TeraFlowAliasNames = ();

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    if ((defined $loadProfilesKey->{'FTP_Get'}) && ($FtpGetEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Get";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharFtpGetId;
        }
        else {
          $Alias = $defaultFtpGetAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@FtpGetAliasNames) == 0) {
          push(@FtpGetAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if (lc($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if (lc($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if (lc($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if (lc($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }

    if ((defined $loadProfilesKey->{'FTP_Put'}) && ($FtpPutEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Put";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharFtpPutId;
        }
        else {
          $Alias = $defaultFtpPutAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@FtpPutAliasNames) == 0) {
          push(@FtpPutAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }

    if ((defined $loadProfilesKey->{'HTTP'}) && ($HttpEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharHttpId;
        }
        else {
          $Alias = $defaultHttpAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
          push(@HttpAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }

    if ((defined $loadProfilesKey->{'SHTTP'}) && ($HttpEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'SHTTP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'SHTTP'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_SHTTP";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharShttpId;
        }
        else {
          $Alias = $defaultShttpAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
          push(@HttpAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }



    if ((defined $loadProfilesKey->{'TWAMP'}) && ($TwampEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_TWAMP";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharTwampId;
        }
        else {
          $Alias = $defaultTwampAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@TwampAliasNames) == 0) {
          push(@TwampAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }

      if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VOIP";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharVoIPId;
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            # Only create TCP Characteristics if the transport type is not UDP.
            if (defined $thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'}) {
              if ($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'} ne "TCP") {
                $TCP_Enabled = 0;
              }
            }
            else {
              $TCP_Enabled = 0;
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }


    if ((defined $loadProfilesKey->{'TeraFlow'}) && ($TeraFlowEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_tf";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharTeraFlowId;
        }
        else {
          $Alias = $defaultTeraFlowAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@TeraFlowAliasNames) == 0) {
          push(@TeraFlowAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if ($TCP_Enabled == 1) {
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }


    if ((defined $loadProfilesKey->{'RTSP'}) && ($RtspEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
      }

      foreach (@{$thisKey}) {
        $TCP_Enabled = 0;

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP";
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharRtspId;
        }
        else {
          $Alias = $defaultRtspAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
          push(@RtspAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {

            $WindowScale = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} >= 0) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'} <= 14)) {
                $WindowScale = $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'};
                $TCP_Enabled = 1;
              }
            }

            $UseSACKWhenPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'} eq "true") {
                $UseSACKWhenPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $SetSACKPermitted = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'} eq "true") {
                $SetSACKPermitted = "true";
                $TCP_Enabled = 1;
              }
            }

            $MaxAdvertisedReceivedWindowSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) {
              if (($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} >= 2) && ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'} <= 65525)) {
                $MaxAdvertisedReceivedWindowSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'};
                $TCP_Enabled = 1;
              }
            }

            $MaxTransmitBufferSize = "";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'} > 0) {
                $MaxTransmitBufferSize = $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Transmit_Buffer_Size'};
                $TCP_Enabled = 1;
              }
            }

            $SupportTimestampWhenRequested = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'} eq "true") {
                $SupportTimestampWhenRequested = "true";
                $TCP_Enabled = 1;
              }
            }

            $RequestTimestamp = "false";
            if (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'}) {
              if ($thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'} eq "true") {
                $RequestTimestamp = "true";
                $TCP_Enabled = 1;
              }
            }

            if (($TCP_Enabled == 1) && ($thisKey->[$i]->{'Media_Stream_Method'} eq 'TCP')){
              $Tg->Add(diversifEye::TcpCharacteristics->new(name=>$TcpCharacteristicsName, tcp_profile_max_transmit_buffer_size=>$MaxTransmitBufferSize, tcp_profile_max_advert_recv_window_size=>$MaxAdvertisedReceivedWindowSize, tcp_window_scale=>$WindowScale,  tcp_profile_use_sack_when_permitted=>$UseSACKWhenPermitted, tcp_profile_set_sack_permitted=>$SetSACKPermitted, tcp_supp_timestamp_when_req=>$SupportTimestampWhenRequested, tcp_req_timestamp=>$RequestTimestamp));
            }
          }
        }
        $i = $i + 1;
      }
    }
  }
}

### Streaming Profiles
printf(STDERR "%s\n", 'Generating Streaming Profiles ...');


### VoIP Codecs
printf(STDERR "%s\n", 'Generating VoIP Codecs ...');
for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    @VoipAliasNames = ();
    if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {
        # Set some defaults for the media codec.
        $thisCodecName = "Default G.711a (PCMA)";
        $thisCodecUsedFor = "Voice Only";
        $thisCodecEncodingName = "mpeg4-generic";
        $thisCodecMediaType = "audio";
        $thisCodecPayloadType = "3";
        $thisCodecPayloadSize = "33";
        $thisCodecmsPacket = "20.0";
        $thisCodecDelay = "";
        $thisCodecStreamRate = "";
        $thisCodecFrequency = "8000";  # in Hz
        $thisCodecChannels = "None";
        $thisCodecDataFile = "";

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VOIP";
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);

          $codecKey = ();
          if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}) {
            $codecKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'};
            $j = 0;

            if (!($codecKey =~ /ARRAY/)) {
              $codecKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}];
            }

            foreach (@{$codecKey}) {
              if (defined $codecKey->[$j]->{'Codec_Name'}) {
                if ($codecKey->[$j]->{'Codec_Name'} ne "") {
                  $thisCodecName = $codecKey->[$j]->{'Codec_Name'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Used_For'}) {
                if ($codecKey->[$j]->{'Codec_Used_For'} eq "Streaming") {
                  $thisCodecUsedFor = "Streaming";
                }
                elsif ($codecKey->[$j]->{'Codec_Used_For'} eq "PCAP") {
                  $thisCodecUsedFor = "Pcap Replay";
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Encoding_Name'}) {
                if ($codecKey->[$j]->{'Codec_Encoding_Name'} ne "") {
                    $thisCodecEncodingName = $codecKey->[$j]->{'Codec_Encoding_Name'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Media_Type'}) {
                if (($thisCodecUsedFor eq "Streaming") && ($codecKey->[$j]->{'Codec_Media_Type'} eq "video")){
                  $thisCodecMediaType = "video";
                }
                if (($thisCodecUsedFor eq "Pcap Replay") && ($codecKey->[$j]->{'Codec_Media_Type'} eq "video")){
                  $thisCodecMediaType = "video";
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Payload_Type'}) {
                if ($codecKey->[$j]->{'Codec_Payload_Type'} ne "") {
                  $thisCodecPayloadType = $codecKey->[$j]->{'Codec_Payload_Type'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Payload_Size'}) {
                if ($codecKey->[$j]->{'Codec_Payload_Size'} ne "") {
                  $thisCodecPayloadSize = $codecKey->[$j]->{'Codec_Payload_Size'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_ms_Packet'}) {
                if (($thisCodecMediaType eq "audio") && ($codecKey->[$j]->{'Codec_ms_Packet'} ne "")){
                  $thisCodecmsPacket = $codecKey->[$j]->{'Codec_ms_Packet'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Delay'}) {
                if ($codecKey->[$j]->{'Codec_Delay'} ne "") {
                  $thisCodecDelay = $codecKey->[$j]->{'Codec_Delay'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Stream_Rate'}) {
                if (($thisCodecMediaType eq "video") && ($codecKey->[$j]->{'Codec_Stream_Rate'} ne "")) {
                  $thisCodecStreamRate = $codecKey->[$j]->{'Codec_Stream_Rate'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Frequency'}) {
                if ($codecKey->[$j]->{'Codec_Frequency'} ne "") {
                  $thisCodecFrequency = $codecKey->[$j]->{'Codec_Frequency'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Channels'}) {
                if ($thisCodecMediaType eq "audio") {
                 if (($codecKey->[$j]->{'Codec_Channels'} eq "1") || ($codecKey->[$j]->{'Codec_Channels'} eq "2")){
                    $thisCodecChannels = $codecKey->[$j]->{'Codec_Channels'};
                  }
                }
              }

              # WARNING - If the file does not exist in /home/cli then provisioning WILL fail
              if (defined $codecKey->[$j]->{'Codec_Data_File'}) {
                $thisCodecDataFile = $codecKey->[$j]->{'Codec_Data_File'};
              }

              $thisSdpAttribList = "";
              if (defined $codecKey->[$j]->{'SDP_Attributes'}) {
                if ($codecKey->[$j]->{'SDP_Attributes'} ne "") {
                  $thisSdpAttribList = diversifEye::SdpAttributeList->new();
                  if ( index($codecKey->[$j]->{'SDP_Attributes'}, " ") != -1 ) {
                    @thisSdpAttributes = split(/ /, $codecKey->[$j]->{'SDP_Attributes'});
                    foreach (@thisSdpAttributes) {
                      $thisSdpAttribList->Add(diversifEye::SdpAttribute->new(attribute=>$_));
                    }
                  }
                  else {
                    $thisSdpAttribList->Add(diversifEye::SdpAttribute->new(attribute=>$codecKey->[$j]->{'SDP_Attributes'}));
                  }
                }
              }

              $thisCodecExists = 0;
              foreach $createdCodecName (@createdCodecs) {
                if ($thisCodecName eq $createdCodecName) {
                  $thisCodecExists = 1;
                  last;
                }
              }

              if ($thisCodecExists == 0) {
                # only add a codec if it is not one of the DiversifEye default ones or that has not already been created with the same name...
                $Tg->Add(diversifEye::RtpCodec->new(name=>$thisCodecName, used_for=>$thisCodecUsedFor, encoding_name=>$thisCodecEncodingName, media_type=>$thisCodecMediaType, payload_type=>$thisCodecPayloadType, payload_size=>$thisCodecPayloadSize, ms_packet=>$thisCodecmsPacket, delay=>$thisCodecDelay, stream_rate=>$thisCodecStreamRate, stream_rate_metric=>'kbit/s', frequency=>$thisCodecFrequency, frequency_metric=>'Hz', channels=>$thisCodecChannels, data_file=>$thisCodecDataFile, sdp_attributes=>$thisSdpAttribList));
                push(@createdCodecs, $thisCodecName);
              }

              $j = $j + 1;

            }
          }
        }
        $i = $i + 1;
      }
    }
  }
}


### RTSP Codecs
printf(STDERR "%s\n", 'Generating RTSP Codecs ...');

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

  @RtspAliasNames = ();
  if ((defined $loadProfilesKey->{'RTSP'}) && ($RtspEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
      }

      foreach (@{$thisKey}) {
        # Set some defaults for the media codec.
        $thisCodecExists = 1;

        $thisCodecName = "MPEG2";
        $thisCodecUsedFor = "Streaming";
        $thisCodecEncodingName = "MPEG2-TS";
        $thisCodecMediaType = "video";
        $thisCodecPayloadType = "32";
        $thisCodecPayloadSize = "1316";
        $thisCodecmsPacket = "20.0";
        $thisCodecDelay = "";
        $thisCodecStreamRate = "";
        $thisCodecFrequency = "9000";  # in Hz
        $thisCodecChannels = "None";
        $thisCodecDataFile = "";

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP";
        }
        else {
          $Alias = $defaultRtspAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
          push(@RtspAliasNames, $AliasEntryName);

          $codecKey = ();
          if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}) {
            $codecKey = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'};
            $j = 0;

            if (!($codecKey =~ /ARRAY/)) {
              $codecKey = [$thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}];
            }

            foreach (@{$codecKey}) {
              if (defined $codecKey->[$j]->{'Codec_Name'}) {
                if ($codecKey->[$j]->{'Codec_Name'} ne "") {
                  $thisCodecName = $codecKey->[$j]->{'Codec_Name'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Used_For'}) {
                if ($codecKey->[$j]->{'Codec_Used_For'} eq "Streaming") {
                  $thisCodecUsedFor = "Streaming";
                }
                elsif ($codecKey->[$j]->{'Codec_Used_For'} eq "PCAP") {
                  $thisCodecUsedFor = "Pcap Replay";
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Encoding_Name'}) {
                if ($codecKey->[$j]->{'Codec_Encoding_Name'} ne "") {
                    $thisCodecEncodingName = $codecKey->[$j]->{'Codec_Encoding_Name'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Media_Type'}) {
                if (($thisCodecUsedFor eq "Streaming") && ($codecKey->[$j]->{'Codec_Media_Type'} eq "video")){
                  $thisCodecMediaType = "video";
                }
                if (($thisCodecUsedFor eq "Pcap Replay") && ($codecKey->[$j]->{'Codec_Media_Type'} eq "video")){
                  $thisCodecMediaType = "video";
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Payload_Type'}) {
                if ($codecKey->[$j]->{'Codec_Payload_Type'} ne "") {
                  $thisCodecPayloadType = $codecKey->[$j]->{'Codec_Payload_Type'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Payload_Size'}) {
                if ($codecKey->[$j]->{'Codec_Payload_Size'} ne "") {
                  $thisCodecPayloadSize = $codecKey->[$j]->{'Codec_Payload_Size'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_ms_Packet'}) {
                if (($thisCodecMediaType eq "audio") && ($codecKey->[$j]->{'Codec_ms_Packet'} ne "")){
                  $thisCodecmsPacket = $codecKey->[$j]->{'Codec_ms_Packet'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Delay'}) {
                if ($codecKey->[$j]->{'Codec_Delay'} ne "") {
                  $thisCodecDelay = $codecKey->[$j]->{'Codec_Delay'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Stream_Rate'}) {
                if (($thisCodecMediaType eq "video") && ($codecKey->[$j]->{'Codec_Stream_Rate'} ne "")) {
                  $thisCodecStreamRate = $codecKey->[$j]->{'Codec_Stream_Rate'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Frequency'}) {
                if ($codecKey->[$j]->{'Codec_Frequency'} ne "") {
                  $thisCodecFrequency = $codecKey->[$j]->{'Codec_Frequency'};
                }
              }

              if (defined $codecKey->[$j]->{'Codec_Channels'}) {
                if ($thisCodecMediaType eq "audio") {
                 if (($codecKey->[$j]->{'Codec_Channels'} eq "1") || ($codecKey->[$j]->{'Codec_Channels'} eq "2")){
                    $thisCodecChannels = $codecKey->[$j]->{'Codec_Channels'};
                  }
                }
              }

              # WARNING - If the file does not exist in /home/cli then provisioning WILL fail
              if (defined $codecKey->[$j]->{'Codec_Data_File'}) {
                $thisCodecDataFile = $codecKey->[$j]->{'Codec_Data_File'};
              }

              $thisSdpAttribList = "";
              if (defined $codecKey->[$j]->{'SDP_Attributes'}) {
                if ($codecKey->[$j]->{'SDP_Attributes'} ne "") {
                  $thisSdpAttribList = diversifEye::SdpAttributeList->new();
                  if ( index($codecKey->[$j]->{'SDP_Attributes'}, " ") != -1 ) {
                    @thisSdpAttributes = split(/ /, $codecKey->[$j]->{'SDP_Attributes'});
                    foreach (@thisSdpAttributes) {
                      $thisSdpAttribList->Add(diversifEye::SdpAttribute->new(attribute=>$_));
                    }
                  }
                  else {
                    $thisSdpAttribList->Add(diversifEye::SdpAttribute->new(attribute=>$codecKey->[$j]->{'SDP_Attributes'}));
                  }
                }
              }

              $thisCodecExists = 0;
              foreach $createdCodecName (@createdCodecs) {
                if ($thisCodecName eq $createdCodecName) {
                  $thisCodecExists = 1;
                  last;
                }
              }

              if ($thisCodecExists == 0) {
                # only add a codec if it is not one of the DiversifEye default ones or that has not already been created with the same name...
                $Tg->Add(diversifEye::RtpCodec->new(name=>$thisCodecName, used_for=>$thisCodecUsedFor, encoding_name=>$thisCodecEncodingName, media_type=>$thisCodecMediaType, payload_type=>$thisCodecPayloadType, payload_size=>$thisCodecPayloadSize, ms_packet=>$thisCodecmsPacket, delay=>$thisCodecDelay, stream_rate=>$thisCodecStreamRate, stream_rate_metric=>'kbit/s', frequency=>$thisCodecFrequency, frequency_metric=>'Hz', channels=>$thisCodecChannels, data_file=>$thisCodecDataFile, sdp_attributes=>$thisSdpAttribList));
                push(@createdCodecs, $thisCodecName);
              }
              $j = $j + 1;
            }
          }
        }
        $i = $i + 1;
      }
    }
  }
}

$thisCodecExists = 0;
foreach $createdCodecName (@createdCodecs) {
    if ($createdCodecName eq "MPEG2") {
        $thisCodecExists = 1;
        last;
   }
}

if ($thisCodecExists == 0) {
    $Tg->Add(diversifEye::RtpCodec->new(name=>"MPEG2", used_for=>'Streaming', encoding_name=>'MPEG2-TS', media_type=>'video', payload_type=>"32", stream_rate=>"5", stream_rate_metric=>"Mbit/s", payload_size=>'1316', frequency=>"90000"));
    push(@createdCodecs, "MPEG2");
}

### VoIP Stream Profile
printf(STDERR "%s\n", 'Generating VoIP Stream Profiles ...');

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    @VoipAliasNames = ();

    if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {
        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName."_VOIP";
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);

          # Set some defaults for the media profiles.
          $thisCodecName = "Default G.711a (PCMA)";
          $thisMediaType = "Voice Only";
          $thisRTPData = "Full Duplex";
          $thisRTCP = "true";
          $thisSilenceSuppression = "true";
          $thisSilenceRatio = "50";
          $thisSilenceLength = "3000";
          $thisAdaptiveBitRateLevelList = "";
          $thisAdaptiveBitRateCodec = "";
          $thisAmrCodecDefined = 0;

          if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}) {
            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Media_Type'}) {
              if ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Media_Type'} eq "Multimedia") {
                $thisMediaType = "Multimedia";
              }
            }

            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTP_Data'}) {
              if ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTP_Data'} eq "Half Duplex Receive") {
                $thisRTPData = "Half Duplex Receive";
              }
              elsif ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTP_Data'} eq "Half Duplex Send") {
                $thisRTPData = "Half Duplex Send";
              }
            }

            if (($thisMediaType eq "Multimedia") && ($VERSION < 10.2)) {
              $thisRTCP = "false";
              $thisSilenceSuppression = "false";
            }
            else {
              if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTCP'}) {
                if ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTCP'} eq "false") {
                  $thisRTCP = "false";
                }
                elsif ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'RTCP'} eq "true") {
                  $thisRTCP = "true";
                }
              }

              if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Suppression'}) {
                if ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Suppression'} eq "false") {
                  $thisSilenceSuppression = "false";
                }
                elsif ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Suppression'} eq "true") {
                  $thisSilenceSuppression = "true";
                }
              }
            }

            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Ratio'}) {
              $thisSilenceRatio = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Ratio'};
              if ($thisSilenceRatio > 80) {
                $thisSilenceRatio = 80;
              }
              elsif ($thisSilenceRatio < 20) {
                $thisSilenceRatio = 20;
              }
            }

            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Length'}) {
              $thisSilenceLength = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Silence_Length'};
              if ($thisSilenceLength > 60000) {
                $thisSilenceLength = 60000;
              }
              elsif ($thisSilenceLength < 1000) {
                $thisSilenceLength = 1000;
              }
            }

            if ($VERSION >= 10.2) {

              $codecKey = ();
              if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}) {
                $codecKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'};
                $j = 0;

                if (!($codecKey =~ /ARRAY/)) {
                  $codecKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}];
                }
                foreach (@{$codecKey}) {
                  if (defined $codecKey->[$j]->{'Codec_Name'}) {
                    if ($codecKey->[$j]->{'Codec_Name'} eq "Default AMR-NB") {
                      $thisAmrCodecDefined = 1;
                    }
                    elsif ($codecKey->[$j]->{'Codec_Name'} eq "Default AMR-WB") {
                      $thisAmrCodecDefined = 1;
                    }
                  }

                  if (defined $codecKey->[$j]->{'Codec_Encoding_Name'}) {
                    if ($codecKey->[$j]->{'Codec_Encoding_Name'} eq "AMR-NB") {
                      $thisAmrCodecDefined = 1;
                    }
                    elsif ($codecKey->[$j]->{'Codec_Encoding_Name'} eq "AMR-WB") {
                      $thisAmrCodecDefined = 1;
                    }
                  }
                  $j = $j + 1;
                }
              }

              if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}) {
                if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'}) {
                  if (($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'} eq "AMR-WB") || ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'} eq "AMR-NB")) {
                    $thisAdaptiveBitRateCodec = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'};
                  }
                }

                if (($thisAdaptiveBitRateCodec ne "") && ($thisAmrCodecDefined == 1)) {
                  if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Use_Default_List'}) {
                    if ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Use_Default_List'} eq "true") {
                      $thisAdaptiveBitRateLevelList = "Default ".$thisAdaptiveBitRateCodec." Levels";
                    }
                  }

                  if ($thisAdaptiveBitRateLevelList eq "") {
                    $levelsKey = ();
                    if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}) {

                      if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'}) {
                        $levelsKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'};
                        $j = 0;

                        if (!($levelsKey =~ /ARRAY/)) {
                          $levelsKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'}];
                        }

                        if (scalar @{$levelsKey} >= 2) {
                          foreach (@{$levelsKey}) {

                            $thisAdaptiveBitRate = "";
                            $thisAdaptivePcapFile = "";

                            if (defined $levelsKey->[$j]->{'BitRate'}) {
                              if ($levelsKey->[$j]->{'BitRate'} ne "") {
                                $thisAdaptiveBitRate = $levelsKey->[$j]->{'BitRate'};
                              }
                            }

                            if (defined $levelsKey->[$j]->{'pCapFile'}) {
                              if ($levelsKey->[$j]->{'pCapFile'} ne "") {
                                $thisAdaptivePcapFile = $levelsKey->[$j]->{'pCapFile'};
                              }
                            }

                            if (($thisAdaptiveBitRate ne "") && ($thisAdaptivePcapFile ne "")) {
                              if ($thisAdaptiveBitRateLevelList eq "") {
                                $thisAdaptiveBitRateLevelList = $Alias.$rangeStr.$suffix;
                                $Brll = diversifEye::BitRateLevelList->new(name=>$thisAdaptiveBitRateLevelList);
                              }

                              $Pfn = File::Spec->catfile($Rd, $thisAdaptivePcapFile);
                              $Brll->Add(diversifEye::BitRateLevel->new(rate=>$thisAdaptiveBitRate, data=>$Pfn));

                            }

                            $j = $j + 1;
                          }

                          if ($thisAdaptiveBitRateLevelList ne "") {
                            $Tg->Add($Brll);
                          }
                        }
                      }
                    }
                  }
                }
              }

              $Rsp = diversifEye::RtpStreamProfile->new(name=>$Alias.$rangeStr.$suffix, used_for=>$thisMediaType, rtcp=>$thisRTCP, rtp_data=>$thisRTPData, silence_suppression_enabled=>$thisSilenceSuppression, silence_ratio=>$thisSilenceRatio, silence_length=>$thisSilenceLength, adaptive_bit_rate_level_list=>$thisAdaptiveBitRateLevelList);
            }
            else {
              $Rsp = diversifEye::RtpStreamProfile->new(name=>$Alias.$rangeStr.$suffix, used_for=>$thisMediaType, rtcp=>$thisRTCP, rtp_data=>$thisRTPData, silence_suppression_enabled=>$thisSilenceSuppression, silence_ratio=>$thisSilenceRatio, silence_length=>$thisSilenceLength);
            }

            $codecKey = ();
            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}) {
              $codecKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'};
              $j = 0;

              if (!($codecKey =~ /ARRAY/)) {
                $codecKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Codec'}];
              }
              foreach (@{$codecKey}) {
                if (defined $codecKey->[$j]->{'Codec_Name'}) {
                  if ($codecKey->[$j]->{'Codec_Name'} ne "") {
                    $thisCodecName = $codecKey->[$j]->{'Codec_Name'};
                  }
                }

                $thisCodecExists = 0;
                foreach $createdCodecName (@createdCodecs) {
                  if ($thisCodecName eq $createdCodecName) {
                    $thisCodecExists = 1;
                    last;
                  }
                }

                # Codec must exist to be added to the profile.
                if ($thisCodecExists == 1) {
                  $Rsp->Add(diversifEye::RtpStreamProfileEntry->new(name=>$thisCodecName));
                }
                $j =$j + 1;
              }
            }
            else {
              $thisCodecExists = 0;
              foreach $createdCodecName (@createdCodecs) {
                if ($thisCodecName eq $createdCodecName) {
                  $thisCodecExists = 1;
                  last;
                }
              }

              if ($thisCodecExists == 1) {
                $Rsp->Add(diversifEye::RtpStreamProfileEntry->new(name=>$thisCodecName));
              }
            }
            $Tg->Add($Rsp);
          }
        }
        $i = $i + 1;
      }
    }
  }
}

### Rtsp Stream Profile
printf(STDERR "%s\n", 'Generating RTSP Stream Profiles ...');

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    @RtspAliasNames = ();
    if ((defined $loadProfilesKey->{'RTSP'}) && ($RtspEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
      }

      foreach (@{$thisKey}) {
        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName."_RTSP";
        }
        else {
          $Alias = $defaultRtspAlias;
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
          push(@RtspAliasNames, $AliasEntryName);
          if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}) {

            # Set some defaults for the media profiles.
            $thisMediaType = "Multimedia";
            $thisRTPData = "Half Duplex Send";
            $thisRTCP = "false";
            $thisSilenceSuppression = "false";
            $thisSilenceRatio = "50";
            $thisSilenceLength = "3000";
            $thisAdaptiveBitRateLevelList = "";
            $thisCodecName = "MPEG2";

            if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Media_Type'}) {
              if ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Media_Type'} eq "Multimedia") {
                $thisMediaType = "Multimedia";
              }
            }

            if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTP_Data'}) {
              if ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTP_Data'} eq "Half Duplex Receive") {
                $thisRTPData = "Half Duplex Receive";
              }
              elsif ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTP_Data'} eq "Half Duplex Send") {
                $thisRTPData = "Half Duplex Send";
              }
            }

            if (($thisMediaType eq "Multimedia") && ($VERSION < 10.2)){
              $thisRTCP = "false";
              $thisSilenceSuppression = "false";
            }
            else {
              if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTCP'}) {
                if ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTCP'} eq "false") {
                  $thisRTCP = "false";
                }
                elsif ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'RTCP'} eq "true") {
                  $thisRTCP = "true";
                }
              }

              if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Suppression'}) {
                if ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Suppression'} eq "true") {
                  $thisSilenceSuppression = "true";
                }
                elsif ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Suppression'} eq "false") {
                  $thisSilenceSuppression = "false";
                }
              }
            }

            if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Ratio'}) {
              $thisSilenceRatio = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Ratio'};
              if ($thisSilenceRatio > 80) {
                $thisSilenceRatio = 80;
              }
              elsif ($thisSilenceRatio < 20) {
                $thisSilenceRatio = 20;
              }
            }

            if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Length'}) {
              $thisSilenceLength = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Silence_Length'};
              if ($thisSilenceLength > 60000) {
                $thisSilenceLength = 60000;
              }
              elsif ($thisSilenceLength < 1000) {
                $thisSilenceLength = 1000;
              }
            }

            if ($VERSION >= 10.2) {
              $codecKey = ();
              if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}) {
                $codecKey = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'};
                $j = 0;

                if (!($codecKey =~ /ARRAY/)) {
                  $codecKey = [$thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}];
                }
                foreach (@{$codecKey}) {
                  if (defined $codecKey->[$j]->{'Codec_Name'}) {
                    if ($codecKey->[$j]->{'Codec_Name'} eq "Default AMR-NB") {
                      $thisAmrCodecDefined = 1;
                    }
                    elsif ($codecKey->[$j]->{'Codec_Name'} eq "Default AMR-WB") {
                      $thisAmrCodecDefined = 1;
                    }
                  }

                  if (defined $codecKey->[$j]->{'Codec_Encoding_Name'}) {
                    if ($codecKey->[$j]->{'Codec_Encoding_Name'} eq "AMR-NB") {
                      $thisAmrCodecDefined = 1;
                    }
                    elsif ($codecKey->[$j]->{'Codec_Encoding_Name'} eq "AMR-WB") {
                      $thisAmrCodecDefined = 1;
                    }
                  }
                  $j = $j + 1;
                }
              }

              if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}) {
                if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'}) {
                  if (($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'} eq "AMR-WB") || ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'} eq "AMR-NB")) {
                    $thisAdaptiveBitRateCodec = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Codec_Type'};
                  }
                }

                if (($thisAdaptiveBitRateCodec ne "") && ($thisAmrCodecDefined == 1)) {
                  if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Use_Default_List'}) {
                    if ($thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Use_Default_List'} eq "true") {
                      $thisAdaptiveBitRateLevelList = "Default ".$thisAdaptiveBitRateCodec." Levels";
                    }
                  }


                  if ($thisAdaptiveBitRateLevelList eq "") {
                    $levelsKey = ();
                    if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}) {
                      if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'}) {
                        $levelsKey = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'};
                        $j = 0;

                        if (!($levelsKey =~ /ARRAY/)) {
                          $levelsKey = [$thisKey->[$i]->{'RTSP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Level_List'}->{'Level_Entry'}];
                        }

                        if (scalar @{$levelsKey} >= 2) {
                          foreach (@{$levelsKey}) {

                            $thisAdaptiveBitRate = "";
                            $thisAdaptivePcapFile = "";

                            if (defined $levelsKey->[$j]->{'BitRate'}) {
                              if (($levelsKey->[$j]->{'BitRate'} > 1) && ($levelsKey->[$j]->{'BitRate'} < 200000)) {
                                $thisAdaptiveBitRate = $levelsKey->[$j]->{'BitRate'};
                              }
                            }

                            if (defined $levelsKey->[$j]->{'pCapFile'}) {
                              if ($levelsKey->[$j]->{'pCapFile'} ne "") {
                                $thisAdaptivePcapFile = $levelsKey->[$j]->{'pCapFile'};
                              }
                            }

                            if (($thisAdaptiveBitRate ne "") && ($thisAdaptivePcapFile ne "")) {
                              if ($thisAdaptiveBitRateLevelList eq "") {
                                $thisAdaptiveBitRateLevelList = $Alias.$rangeStr.$suffix;
                                $Brll = diversifEye::BitRateLevelList->new(name=>$thisAdaptiveBitRateLevelList);
                              }

                              $Pfn = File::Spec->catfile($Rd, $thisAdaptivePcapFile);
                              $Brll->Add(diversifEye::BitRateLevel->new(rate=>$thisAdaptiveBitRate, data=>$Pfn));

                            }

                            $j = $j + 1;
                          }

                          if ($thisAdaptiveBitRateLevelList ne "") {
                            $Tg->Add($Brll);
                          }
                        }
                      }
                    }
                  }
                }
              }

              $Rtsp = diversifEye::RtpStreamProfile->new(name=>$Alias.$rangeStr.$suffix, used_for=>$thisMediaType, rtcp=>$thisRTCP, rtp_data=>$thisRTPData, silence_suppression_enabled=>$thisSilenceSuppression, silence_ratio=>$thisSilenceRatio, silence_length=>$thisSilenceLength, adaptive_bit_rate_level_list=>$thisAdaptiveBitRateLevelList);
            }
            else {
              $Rtsp = diversifEye::RtpStreamProfile->new(name=>$Alias.$rangeStr.$suffix, used_for=>$thisMediaType, rtcp=>$thisRTCP, rtp_data=>$thisRTPData, silence_suppression_enabled=>$thisSilenceSuppression, silence_ratio=>$thisSilenceRatio, silence_length=>$thisSilenceLength);
            }

            $codecKey = ();
            if (defined $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}) {
              $codecKey = $thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'};
              $j = 0;

              if (!($codecKey =~ /ARRAY/)) {
                $codecKey = [$thisKey->[$i]->{'RTSP_Media_Profile'}->{'Codec'}];
              }
              foreach (@{$codecKey}) {
                if (defined $codecKey->[$j]->{'Codec_Name'}) {
                  if ($codecKey->[$j]->{'Codec_Name'} ne "") {
                    $thisCodecName = $codecKey->[$j]->{'Codec_Name'};
                  }
                }

                # Codec must exist to be added to the profile.
                $thisCodecExists = 0;
                foreach $createdCodecName (@createdCodecs) {
                  if ($thisCodecName eq $createdCodecName) {
                    $thisCodecExists = 1;
                    last;
                  }
                }

                if ($thisCodecExists == 1) {
                  $Rtsp->Add(diversifEye::RtpStreamProfileEntry->new(name=>$thisCodecName));
                }
                $j =$j + 1;
              }
            }
            else {
              $thisCodecExists = 0;
              foreach $createdCodecName (@createdCodecs) {
                if ($thisCodecName eq $createdCodecName) {
                  $thisCodecExists = 1;
                  last;
                }
              }

              if ($thisCodecExists == 1) {
                $Rtsp->Add(diversifEye::RtpStreamProfileEntry->new(name=>$thisCodecName));
              }
            }

            $Tg->Add($Rtsp);
          }
        }
        $i = $i + 1;
      }
    }
  }
}

printf(STDERR "%s\n", 'Generating Adaptive Change Lists ...');
for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    @VoipAliasNames = ();

      if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {
        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName."_VOIP";
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr.$suffix."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);

          if ((defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}) && ($VERSION >= 10.2)) {
            $thisAdaptiveChangeList = "";
            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}) {

              if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'}) {
                $changesKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'};
                $j = 0;

                if (!($changesKey =~ /ARRAY/)) {
                  $changesKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'}];
                }

                if (scalar @{$changesKey} >= 1) {
                  foreach (@{$changesKey}) {
                    if (($changesKey->[$j] > 0) && ($changesKey->[$j] < 99)) {
                      if ($thisAdaptiveChangeList eq "") {
                        $thisAdaptiveChangeList = $Alias.$rangeStr.$suffix;
                        $Brlcl = diversifEye::BitRateLevelChangeList->new(name=>$thisAdaptiveChangeList);
                      }
                      $Brlcl->Add(diversifEye::BitRateLevelChange->new(change_type=>'Bit Rate Level', bit_rate_level=>$changesKey->[$j]));
                    }
                    $j = $j + 1;
                  }

                  if ($thisAdaptiveChangeList ne "") {
                    $Tg->Add($Brlcl);
                  }
                }
              }
            }
          }
        }
      $i = $i + 1;
      }
    }
  }
}



if ($RtspEnabled eq 1) {
  $Pe = diversifEye::ServerMediaContentList->new(name=>'Internal Server Resource List');
  @RtspAliasNames = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'RTSP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP";
          }
          else {
            $Alias = $defaultRtspAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
            push(@RtspAliasNames, $AliasEntryName);
            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

              if (defined $thisKey->[$i]->{'Path'}) {
                $thisRtspPath = $thisKey->[$i]->{'Path'};
              }
              else {
                $thisRtspPath = $RtspPath;
              }

              $stream_profile = $Alias.$rangeStr.$suffix;

              $Tz = diversifEye::ServerMediaContent->new(path=>$thisRtspPath, stream_profile=>$stream_profile);
              $Pe->Add($Tz);

            }
          }
          $i = $i + 1;
        }
      }
    }
  }
  $Tg->Add($Pe);


  @RtspAliasNames = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'RTSP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP";
          }
          else {
            $Alias = $defaultRtspAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
            push(@RtspAliasNames, $AliasEntryName);
            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

              if (defined $thisKey->[$i]->{'Path'}) {
                $thisRtspPath = $thisKey->[$i]->{'Path'};
              }
              else {
                $thisRtspPath = $RtspPath;
              }

              $Rrl = diversifEye::RequestedMediaResourceList->new(name=>$Alias.$rangeStr.$RtspRequestListId.$suffix);
              $Rrl->Add(diversifEye::RequestedMediaResource->new(path=>$thisRtspPath));
              $Tg->Add($Rrl);
            }
          }
          $i = $i + 1;
        }
      }
    }
  }

}


### FTP Request Lists
printf(STDERR "%s\n", 'Generating FTP Request Lists ...');

if ($FtpGetEnabled eq 1) {
  @FtpGetAliasNames = ();
  my @InternalFtpServerResourcePaths = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if ((defined $loadProfilesKey->{'FTP_Get'}) && ($FtpGetEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange  = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Get";
          }
          else {
            $Alias = $defaultFtpGetAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@FtpGetAliasNames) == 0) {
            push(@FtpGetAliasNames, $AliasEntryName);
            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

              $thisFtpGetPath = $FtpGetPath;
              if (defined $thisKey->[$i]->{'Path'}) {
                if ($thisKey->[$i]->{'Path'} ne "") {
                    $thisFtpGetPath = $thisKey->[$i]->{'Path'};
                }
              }

              $nameLen = length($Alias.$rangeStr.$FtpGetCmdListId.$suffix);
              if ($nameLen > 32) {
                 $rangeLen = 32 - length($Alias.$FtpGetCmdListId.$suffix);
                 if ($rangeLen > 0) {
                    $rangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                 }
                 else {
                    $rangeStr = "";
                 }
              }

              $Fgcl = diversifEye::FtpCommandList->new(name=>$Alias.$rangeStr.$FtpGetCmdListId.$suffix);
              $Fgcl->Add(diversifEye::FtpCommand->new(type=>"get", path=>"$thisFtpGetPath"));
              $Tg->Add($Fgcl);
            }
          }
          $i = $i + 1;
        }
      }
    }
  }
}

printf(STDERR "%s\n", 'Generating FTP Resource Lists ...');
$Frl = diversifEye::FtpResourceList->new(name=>"Internal Server Resource List");
$Srl = diversifEye::FtpResourceList->new(name=>"Shared Client Resource List");

@FtpPutClientResourceUrlList = ();

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $profileName = "Default";
    $suffix = "";
  }
  else {
    $profileName = "Profile_$profileId";
    $suffix = "_P$profileId";
  }

  @FtpPutAliasNames = ();
  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    if ((defined $loadProfilesKey->{'FTP_Put'}) && ($FtpPutEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'}];
      }

      foreach (@{$thisKey}) {

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Put";
        }
        else {
          $Alias = $defaultFtpPutAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@FtpPutAliasNames) == 0) {
          push(@FtpPutAliasNames, $AliasEntryName);

          if (defined $thisKey->[$i]->{'Server_Host_Name'}) {

            $thisFtpPutPath = $FtpPutPath;
            if (defined $thisKey->[$i]->{'Path'}) {
              if ($thisKey->[$i]->{'Path'} ne "") {
                $thisFtpPutPath = $thisKey->[$i]->{'Path'};
              }
            }

            $thisFtpPutPathShared = $FtpPutPathShared;
            $thisFtpPutPathIsShared = 0;
            if (defined $thisKey->[$i]->{'Ftp_Put_Path_Shared'}) {
              if ($thisKey->[$i]->{'Ftp_Put_Path_Shared'} ne "") {
                $thisFtpPutPathShared = $thisKey->[$i]->{'Ftp_Put_Path_Shared'};
                $thisFtpPutPathIsShared = 1;
              }
            }

            $thisFtpPutFileSize = $FtpFileSize;
            if (defined $thisKey->[$i]->{'File_Size'}) {
              if ($thisKey->[$i]->{'File_Size'} ne "") {
                $thisFtpPutFileSize = $thisKey->[$i]->{'File_Size'};
              }
            }

            if ($thisFtpPutPathIsShared == 1)
            {
              $nameLen = length($Alias.$rangeStr.$FtpGetCmdListId.$suffix);
              if ($nameLen > 32) {
                 $rangeLen = 32 - length($Alias.$FtpGetCmdListId.$suffix);
                 if ($rangeLen > 0) {
                    $rangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                 }
                 else {
                    $rangeStr = "";
                 }
              }

              $Fpcl = diversifEye::FtpCommandList->new(name=>$Alias.$rangeStr.$FtpPutCmdListId.$suffix);
              $Fpcl->Add(diversifEye::FtpCommand->new(type=>"put", path=>$thisFtpPutPath.$thisFtpPutPathShared));
              $Tg->Add($Fpcl);
            }
            else
            {
              for $ue (0..$conf{UEs}-1)
              {
                for $pdn (0..$conf{PDNs_per_UE}-1)
                {
                  # check if UE and PDN are to be added.
                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $Fpcl = diversifEye::FtpCommandList->new(name=>$Alias.$FtpPutCmdListId."_".$ue."_".$pdn.$suffix);
                    $Fpcl->Add(diversifEye::FtpCommand->new(type=>"put", path=>$thisFtpPutPath."_ue".$ue."_pdn".$pdn.$suffix));
                    $Tg->Add($Fpcl);
                  }
                }
              }
            }



            if ($thisFtpPutPathIsShared)
            {
              # fixed storage for put (shared between clients)
              $thisFtpPutUrl = $thisFtpPutPath.$thisFtpPutPathShared;
              if ((grep /^$thisFtpPutUrl/,@FtpPutClientResourceUrlList) == 0) {
                push(@FtpPutClientResourceUrlList, $thisFtpPutUrl);
                $Srl->Add(diversifEye::FtpResource->new(type=>"Fixed Size", path=>$thisFtpPutUrl, value=>$thisFtpPutFileSize));
              }
            }
            else
            {
              for $ue (0..$conf{UEs}-1)
              {
                for $pdn (0..$conf{PDNs_per_UE}-1)
                {
                  # check if UE and PDN are to be added.
                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }


                  $thisFtpPutUrl = $thisFtpPutPath."_ue".$ue."_pdn".$pdn.$suffix;
                  if (((grep /^$thisFtpPutUrl/,@FtpPutClientResourceUrlList) == 0) && ($createEntry == 1)) {
                    push(@FtpPutClientResourceUrlList, $thisFtpPutUrl);
                    $Srl->Add(diversifEye::FtpResource->new(type=>"Fixed Size", path=>$thisFtpPutUrl, value=>$thisFtpPutFileSize));
                  }
                }
              }
            }
          }
        }
        $i = $i + 1;
      }
    }
  }

  # 1MB Fixed storage for get on server
  @FtpGetAliasNames = ();
  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    if ((defined $loadProfilesKey->{'FTP_Get'}) && ($FtpGetEnabled eq 1)) {
      $thisKey = ();
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'};
      $i = 0;

      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'}];
      }

      foreach (@{$thisKey}) {

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Get";
        }
        else {
          $Alias = $defaultFtpGetAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@FtpGetAliasNames) == 0) {
          push(@FtpGetAliasNames, $AliasEntryName);

          if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

            $thisFtpGetFileSize = $FtpFileSize;
            if (defined $thisKey->[$i]->{'File_Size'}) {
              $thisFtpGetFileSize = $thisKey->[$i]->{'File_Size'};
            }

            $thisFtpGetPath = $FtpGetPath;
            if (defined $thisKey->[$i]->{'Path'}) {
              if ($thisKey->[$i]->{'Path'} ne "") {
                $thisFtpGetPath = $thisKey->[$i]->{'Path'};
              }
            }
            if ((grep /^$thisFtpGetPath/,@InternalFtpServerResourcePaths) == 0) {
              $Frl->Add(diversifEye::FtpResource->new(type=>"Fixed Size", path=>$thisFtpGetPath, value=>$thisFtpGetFileSize));
              push(@InternalFtpServerResourcePaths, $thisFtpGetPath);
            }
          }
        }
        $i = $i + 1;
      }
    }
  }


}

if ($FtpGetEnabled == 1) {
  $Tg->Add($Frl);
}

if ($FtpPutEnabled == 1) {
  $Tg->Add($Srl);
}



### VoIP Call List
printf(STDERR "%s\n", 'Generating VoIP Call Lists ...');
@VoipAliasNames = ();
for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {

        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VoIP";
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);
          if (defined $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}) {

            $thisSIPServer = $SIPServer;
            if (defined $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}) {
              $thisSIPServer = $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}."_voip";
            }

            $thisSIPUsername = $SIPUsername;
            if (defined $thisKey->[$i]->{'SIP_Server'}->{'Username'}) {
              $thisSIPUsername = $thisKey->[$i]->{'SIP_Server'}->{'Username'};
            }

            $thisSIPPassword = $SIPPassword;
            if (defined $thisKey->[$i]->{'SIP_Server'}{'Password'}) {
              $thisSIPPassword = $thisKey->[$i]->{'SIP_Server'}->{'Password'};
            }

            $thisSIPDomain = $SIPDomain;
            if (defined $thisKey->[$i]->{'SIP_Server'}{'Domain'}) {
              $thisSIPDomain = $thisKey->[$i]->{'SIP_Server'}->{'Domain'};
            }

            $thisSIPRegisterWithServer = "true";
            if (defined $thisKey->[$i]->{'SIP_Server'}->{'Register_With_Server'}) {
              if ($thisKey->[$i]->{'SIP_Server'}->{'Register_With_Server'} eq "false") {
                $thisSIPRegisterWithServer = "false";
              }
            }

            $thisSIPDestinationCallURIType = $SIPDestinationCallURIType;
            if (defined $thisKey->[$i]->{'Destination_Call_URI_Is_SIP'}) {
              if ($thisKey->[$i]->{'Destination_Call_URI_Is_SIP'} eq "true") {
                $thisSIPDestinationCallURIType = "SIP";
              }
            }

            ### Generate the call lists
            $thisCallList = ();
            $thisCallList_Enabled = 0;

            if ($useScaledEntities ne 1) {
              if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "List") {
                  if (defined $thisKey->[$i]->{'Mobile_Originated_Call_List'}) {
                    $j = 0;

                    if ($thisKey =~ /ARRAY/) {
                      $callListKey = $thisKey->[$i]->{'Mobile_Originated_Call_List'}->{'UE'};
                      if (!($callListKey =~ /ARRAY/)) {
                        $callListKey = [$thisKey->[$i]->{'Mobile_Originated_Call_List'}->{'UE'}];
                      }
                    }
                    else {
                      $callListKey = $thisKey->{'Mobile_Originated_Call_List'}->{'UE'};
                      if (!($callListKey =~ /ARRAY/)) {
                        $callListKey = [$thisKey->{'Mobile_Originated_Call_List'}->{'UE'}];
                      }
                    }

                    foreach (@{$callListKey}) {
                      if ((defined $callListKey->[$j]->{'UE_Id'}) && (defined $callListKey->[$j]->{'Call'})) {
                        $ue = $callListKey->[$j]->{'UE_Id'};
                        # Expand Special values (All, Even, Odd)
                        if ($ue eq "All") {
                          for $expandedUe (0..$conf{UEs}-1) {

                            $createEntry = 0;
                            if ($UeRange eq "") {
                              $createEntry = 1;
                            }
                            elsif ($UeRange ne "") {
                              if ((isInRange($expandedUe, $UeRange) == 1)) {
                                $createEntry = 1;
                              }
                            }

                            if ($createEntry == 1) {
                              $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$expandedUe;
                              $thisCallList{$voipCallListName} = $callListKey->[$j]->{'Call'};
                              $thisCallList_Enabled = 1;
                            }
                          }
                        }
                        elsif ($ue eq "Odd") {
                          for $expandedUe (0..$conf{UEs}-1) {

                            $createEntry = 0;
                            if ($UeRange eq "") {
                              $createEntry = 1;
                            }
                            elsif ($UeRange ne "") {
                              if ((isInRange($expandedUe, $UeRange) == 1)) {
                                $createEntry = 1;
                              }
                            }

                            if (($expandedUe % 2) && ($createEntry == 1)) {
                              $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$expandedUe;
                              $thisCallList{$voipCallListName} = $callListKey->[$j]->{'Call'};
                              $thisCallList_Enabled = 1;
                            }
                          }
                        }
                        elsif ($ue eq "Even") {
                          for $expandedUe (0..$conf{UEs}-1) {
                            $createEntry = 0;
                            if ($UeRange eq "") {
                              $createEntry = 1;
                            }
                            elsif ($UeRange ne "") {
                              if ((isInRange($expandedUe, $UeRange) == 1)) {
                                $createEntry = 1;
                              }
                            }

                            if (($expandedUe % 2 == 0) && ($createEntry == 1)) {
                              $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$expandedUe;
                              $thisCallList{$voipCallListName} = $callListKey->[$j]->{'Call'};
                              $thisCallList_Enabled = 1;
                            }
                          }
                        }
                        elsif ((index($ue, ".") != -1) || (index($ue, "-") != -1) || (index($ue, ",") != -1)) {
                          for $expandedUe (0..$conf{UEs}-1) {
                            $createEntry = 0;
                            if ($UeRange eq "") {
                              $createEntry = 1;
                            }
                            elsif ($UeRange ne "") {
                              if ((isInRange($expandedUe, $UeRange) == 1)) {
                                $createEntry = 1;
                              }
                            }

                            if ((isInRange($expandedUe, $ue) == 1) && ($createEntry == 1)) {
                              $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$expandedUe;
                              $thisCallList{$voipCallListName} = $callListKey->[$j]->{'Call'};
                              $thisCallList_Enabled = 1;
                            }
                          }
                        }
                        else {
                          $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$ue;
                          $thisCallList{$voipCallListName} = $callListKey->[$j]->{'Call'};
                          $thisCallList_Enabled = 1;
                        }
                      }
                      $j = $j + 1;
                    }
                  }
                }
                elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                  $thisCallList_Enabled = 1;
                  for $ue (0..$conf{UEs}-1) {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue + 1);
                    $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$ue;
                    $thisCallList{$voipCallListName} = $thisSIPUsername;
                    # Check for the numerical addition of UE_ID in the username or substitution
                    $position = rindex($thisCallList{$voipCallListName}, "+%UE_ID%");
                    if ($position != -1) {
                      $numPart = substr($thisCallList{$voipCallListName}, 0, $position);
                      if ($numPart !~ /\D/) {
                        # Is numbers only
                        $thisCallList{$voipCallListName} = ($numPart+$ue)+1;
                      }
                      else {
                        # Contains a prefix.
                        @numberParts = split(/\D+/, $numPart);
                        $numberPart = $numberParts[-1];
                        $position = rindex($numPart, $numberPart);
                        $prefix = substr($numPart, 0, $position);
                        $thisCallList{$voipCallListName} = $prefix.(($numberPart+$ue)+1);
                      }
                    }
                    $thisCallList{$voipCallListName} =~ s/%UE_ID%/$ueStr/g;
                    $thisCallList{$voipCallListName} =~ s/%DOMAIN%/$thisSIPDomain/g;
                    # only add domain if a sip
                    if ($thisSIPDestinationCallURIType eq "SIP") {
                      if ($thisCallList{$voipCallListName} !~ /@/) {
                        $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                      }
                    }
                    else {
                      if (($thisCallList{$voipCallListName} !~ /@/) && ($thisCallList{$voipCallListName} =~ /\D/)) {
                        $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                      }
                    }
                  }
                }
                elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                  $thisCallList_Enabled = 1;
                  for $ue (0..$conf{UEs}-1) {
                    if ($ue % 2) {
                      $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue + 1);
                      $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$ue;
                      $thisCallList{$voipCallListName} = $thisSIPUsername;
                      # Check for the numerical addition of UE_ID in the username or substitution
                      $position = rindex($thisCallList{$voipCallListName}, "+%UE_ID%");
                      if ($position != -1) {
                        $numPart = substr($thisCallList{$voipCallListName}, 0, $position);
                        if ($numPart !~ /\D/) {
                          # Is numbers only
                          $thisCallList{$voipCallListName} = ($numPart+$ue)+1;
                        }
                        else {
                          # Contains a prefix.
                          @numberParts = split(/\D+/, $numPart);
                          $numberPart = $numberParts[-1];
                          $position = rindex($numPart, $numberPart);
                          $prefix = substr($numPart, 0, $position);
                          $thisCallList{$voipCallListName} = $prefix.(($numberPart+$ue)+1);
                        }
                      }
                      $thisCallList{$voipCallListName} =~ s/%UE_ID%/$ueStr/g;
                      $thisCallList{$voipCallListName} =~ s/%DOMAIN%/$thisSIPDomain/g;
                      # only add domain if a sip
                      if ($thisSIPDestinationCallURIType eq "SIP") {
                        if ($thisCallList{$voipCallListName} !~ /@/) {
                          $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                        }
                      }
                      else {
                        if (($thisCallList{$voipCallListName} !~ /@/) && ($thisCallList{$voipCallListName} =~ /\D/)) {
                          $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                        }
                      }
                    }
                  }
                }
                elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                  $thisCallList_Enabled = 1;
                  for $ue (0..$conf{UEs}-1) {
                    if ($ue % 2 == 0) {
                      $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$ue;
                      $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue + 1);
                      $thisCallList{$voipCallListName} = $thisSIPUsername;
                      # Check for the numerical addition of UE_ID in the username or substitution
                      $position = rindex($thisCallList{$voipCallListName}, "+%UE_ID%");
                      if ($position != -1) {
                        $numPart = substr($thisCallList{$voipCallListName}, 0, $position);
                        if ($numPart !~ /\D/) {
                          # Is numbers only
                          $thisCallList{$voipCallListName} = ($numPart+$ue)+1;
                        }
                        else {
                          # Contains a prefix.
                          @numberParts = split(/\D+/, $numPart);
                          $numberPart = $numberParts[-1];
                          $position = rindex($numPart, $numberPart);
                          $prefix = substr($numPart, 0, $position);
                          $thisCallList{$voipCallListName} = $prefix.(($numberPart+$ue)+1);
                        }
                      }
                      $thisCallList{$voipCallListName} =~ s/%UE_ID%/$ueStr/g;
                      $thisCallList{$voipCallListName} =~ s/%DOMAIN%/$thisSIPDomain/g;
                      # Force adding domain if type is configured to SIP
                      if ($thisSIPDestinationCallURIType eq "SIP") {
                        if ($thisCallList{$voipCallListName} !~ /@/) {
                          $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                        }
                      }
                      else {
                        if (($thisCallList{$voipCallListName} !~ /@/) && ($thisCallList{$voipCallListName} =~ /\D/)) {
                          $thisCallList{$voipCallListName} .= "@".$thisSIPDomain;
                        }
                      }
                    }
                  }
                }
              }

              ### Now create the diversifEye entries
              if ($thisCallList_Enabled == 1) {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if ($UeRange eq "") {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && (isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }

                  $voipCallListName = $Alias.$VoipCallListId."_".$profileName."_".$ue;
                  if (defined $thisCallList{$voipCallListName}) {
                    $ueStr =  sprintf("%0${MinimumUeIdDigits}s", $ue);
                    $ThisScheme = "";
                    $ThisUsername = "";
                    if ($thisCallList{$voipCallListName} =~ m/[^a-zA-Z0-9]/){
                      $ThisScheme = "sip";
                      $ThisUsername = $thisCallList{$voipCallListName};
                    }
                    elsif ($thisCallList{$voipCallListName} !~ /\D/) {
                      $ThisScheme = "tel";
                      $ThisUsername = $thisCallList{$voipCallListName};
                    }
                    if (($ThisScheme ne "") && ($ThisUsername ne "")) {
                      $Vcl = diversifEye::VoipCallList->new(name=>$Alias.$VoipCallListId.$ueStr.$suffix);

                      if ($ThisUsername =~ m/[^ ]/) {
                        my @lines = split(' ', $ThisUsername);
                        foreach my $line (@lines) {
                          if ($ThisScheme eq "sip") {
                            ($mySipUser, $mySipDomain) = split("@", $line);
                            if ($createEntry)  {
                              $Vcl->Add(diversifEye::VoipCallListEntry->new(scheme=>$ThisScheme, username=>$mySipUser, hostname=>$mySipDomain));
                            }
                          }
                          else {
                            if ($createEntry)  {
                              $Vcl->Add(diversifEye::VoipCallListEntry->new(scheme=>$ThisScheme, username=>$line));
                            }
                          }
                        }
                      }
                      else {
                        if ($ThisScheme eq "sip") {
                          ($mySipUser, $mySipDomain) = split("@", $ThisUsername);
                          if ($createEntry)  {
                            $Vcl->Add(diversifEye::VoipCallListEntry->new(scheme=>$ThisScheme, username=>$mySipUser, hostname=>$mySipDomain));
                          }
                        }
                        else {
                          if ($createEntry)  {
                            $Vcl->Add(diversifEye::VoipCallListEntry->new(scheme=>$ThisScheme, username=>$ThisUsername));
                          }
                        }
                      }
                      if ($createEntry)  {
                        $Tg->Add($Vcl);
                      }
                    }
                  }
                }
              }
            }
          }
        }
        $i = $i + 1;
      }
    }
  }
}



### SMS Message lists
printf(STDERR "%s\n", 'Generating SMS Message Lists ...');
@VoipAliasNames = ();
for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $suffix = "";
    $profileName = "Default";
  }
  else {
    $suffix = "_P$profileId";
    $profileName = "Profile_$profileId";
  }

  if (defined $ClientProfilesKey->{$profileName} ) {
    $loadProfilesKey = $ClientProfilesKey->{$profileName};

    if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
      $thisKey = ();
      $nextKeyId = 0;

      if (defined $loadProfilesKey->{'VoIP'}) {
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
        }
        foreach (@{$thisKey}) {
          $nextKeyId = $nextKeyId + 1;
        }
      }

      if (defined $loadProfilesKey->{'VoIMS'}) {
        $thisVoimsKey = ();
        $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
        if (!($thisVoimsKey =~ /ARRAY/)) {
          $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
        }
        $i = 0;
        foreach (@{$thisVoimsKey}) {
          $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
          $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
          $i = $i + 1;
          $nextKeyId = $nextKeyId + 1;
        }
      }
      $i = 0;

      foreach (@{$thisKey}) {
        $UeRange = "";
        $PdnRange = "";
        if (defined $thisKey->[$i]->{'UE'}) {
          $UeRange = $thisKey->[$i]->{'UE'};
        }

        if (defined $thisKey->[$i]->{'PDN'}) {
          $PdnRange = $thisKey->[$i]->{'PDN'};
        }
        $rangeStr = cleanRange($UeRange, $PdnRange);

        if (defined $thisKey->[$i]->{'Alias'}) {
          $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VoIP";
        }
        else {
          $Alias = $defaultVoipAlias;
          $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
          push(@VoipAliasNames, $AliasEntryName);

          # Create SMS Message lists
          $thisSmsGateway = "";
          $thisSmsRecipient = "";
          $thisSmsMessage = "";
          if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}) {
            if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Gateway'}) {
              $thisSmsGateway = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Gateway'};
            }

            if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Recipient'}) {
              $thisSmsRecipient = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Recipient'};
            }

            if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Message'}) {
              $thisSmsMessage = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Message'};
            }

            if (($thisSmsGateway ne "") && ($thisSmsGateway ne "") && ($thisSmsGateway ne "")) {
              $Sml = diversifEye::SmsMessageList->new(name=>$Alias.$SmsListId."_".$profileName."_".$rangeStr);
              $Sml->Add(diversifEye::SmsMessage->new(sms_text=>$thisSmsMessage));
              $Tg->Add($Sml);
            }
          }
        }
        $i = $i + 1;
      }
    }
  }
}




if ($HttpEnabled eq 1) {
  ### HTTP Resource List.
  printf(STDERR "%s\n", 'Generating HTTP Resource Lists ...');
  @HttpAliasNames = ();
  @HttpReourcePath = ();
  $Hrl = diversifEye::HttpResourceList->new(name=>"Internal Server Resource List");
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'HTTP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP";
          }
          else {
            $Alias = $defaultHttpAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
            push(@HttpAliasNames, $AliasEntryName);

            $thisHttpGetPath = $HttpGetPath;
            if (defined $thisKey->[$i]->{'Path'}) {
              $thisHttpGetPath = $thisKey->[$i]->{'Path'};
            }

            $thisHttpFileSize = $HttpFileSize;
            if (defined $thisKey->[$i]->{'File_Size'}) {
              $thisHttpFileSize = $thisKey->[$i]->{'File_Size'};
            }

            if (((grep /^$thisHttpGetPath/,@HttpReourcePath) == 0) && ($thisHttpGetPath ne "") ) {
              push(@HttpReourcePath, $thisHttpGetPath);

              $Hrl->Add(diversifEye::HttpResource->new(type=>"Random Data", path=>$thisHttpGetPath, value=>$thisHttpFileSize));
            }
          }
          $i = $i + 1;
        }
      }
    }
  }
  $Tg->Add($Hrl);

  ### HTTP Request List.
  printf(STDERR "%s\n", 'Generating HTTP Request Lists ...');
  @HttpAliasNames = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'HTTP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP";
          }
          else {
            $Alias = $defaultHttpAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
            push(@HttpAliasNames, $AliasEntryName);

            $thisHttpGetPath = $HttpGetPath;
            if (defined $thisKey->[$i]->{'Path'}) {
              $thisHttpGetPath = $thisKey->[$i]->{'Path'};
            }

            $thisHttpPostContent = $HttpPostContent;
            if (defined $thisKey->[$i]->{'POST_Content'}) {
              $thisHttpPostContent = $thisKey->[$i]->{'POST_Content'};
            }


            $thisHttpOperation = $HttpOperation;
            if (defined $thisKey->[$i]->{'Http_Operation'}) {
              if (($thisKey->[$i]->{'Http_Operation'} eq 'POST') || ($thisKey->[$i]->{'Http_Operation'} eq 'HEAD')){
                $thisHttpOperation = $thisKey->[$i]->{'Http_Operation'};
              }
              else {
                $HttpOperation = 'GET';
              }
            }


            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {
              if (index($thisKey->[$i]->{'Path'}, "%UE_ID") != -1) {
                $ueStep = index($thisKey->[$i]->{'Path'}, "+");
                if ($ueStep != -1) {
                  $ueStep = $thisKey->[$i]->{'Path'};
                  $ueStep =~ /\%(.*?)\%/;
                  $ueStep = $1;
                  $matchUeStr = "%".$1."%";
                  $ueStep =~ s/[^0-9]//g;
                }
                else {
                  $ueStep = 0;
                  $matchUeStr = "%UE_ID%";
                }

                for $pdn (0..$PDNs_per_UE-1) {
                  for $ue (0..$conf{UEs}-1) {

                    $createEntry = 0;
                    if (($UeRange eq "") && ($PdnRange eq "")) {
                      $createEntry = 1;
                    }
                    elsif (($UeRange ne "") && ($PdnRange ne "")) {
                      if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                        $createEntry = 1;
                      }
                    }
                    elsif (($UeRange ne "") && ($PdnRange eq "")) {
                      if ((isInRange($ue, $UeRange) == 1)) {
                        $createEntry = 1;
                      }
                    }
                    elsif (($UeRange eq "") && ($PdnRange ne "")) {
                      if ((isInRange($pdn, $PdnRange) == 1)) {
                        $createEntry = 1;
                      }
                    }

                    if ($createEntry)  {
                      $ueStrWithStep = sprintf("%0${MinimumUeIdDigits}s", ($ue * 1) + ($ueStep * 1));

                      $thisTempHttpGetPath = $thisHttpGetPath;
                      $thisTempHttpGetPath =~ s/\Q$matchUeStr\E/$ueStrWithStep/g;
                      $thisTempHttpGetPath =~ s/%PDN%/$pdn/g;

                      $Hrl = diversifEye::HttpRequestList->new(name=>$Alias."_ue".$ue."_pdn".sprintf("%s", $pdn).$HttpRequestListId.$suffix);
                      if ($thisHttpOperation eq "POST") {
                        $Bpl = diversifEye::BodyPartList->new();
                        $Bpl->Add(diversifEye::BodyPart->new(body_data_type=>"Text", content=>"$thisHttpPostContent", content_type=>"text/plain", content_type_charset=>"ascii", content_transfer_enc=>"8bit"));
                        $Hrl->Add(diversifEye::HttpRequest->new(method=>"$thisHttpOperation", uri=>"$thisTempHttpGetPath", content_type=>"multipart/form-data", content=>"$thisHttpPostContent", body_part_list=>$Bpl));
                      }
                      else {
                        $Hrl->Add(diversifEye::HttpRequest->new(method=>"$thisHttpOperation", uri=>"$thisTempHttpGetPath"));
                      }
                      $Tg->Add($Hrl);
                    }
                  }
                }
              }
              else {
                $listRangeStr = $rangeStr;
                $nameLen = length($Alias.$rangeStr.$HttpRequestListId.$suffix);
                if ($nameLen > 32) {
                   $rangeLen = 32 - length($Alias.$HttpRequestListId.$suffix);
                   if ($rangeLen > 0) {
                      $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                   }
                   else {
                      $listRangeStr = "";
                   }
                }
                $Hrl = diversifEye::HttpRequestList->new(name=>$Alias.$listRangeStr.$HttpRequestListId.$suffix);
                if ($thisHttpOperation eq "POST") {
                  $Bpl = diversifEye::BodyPartList->new();
                  $Bpl->Add(diversifEye::BodyPart->new(body_data_type=>"Text", content=>"$thisHttpPostContent", content_type=>"text/plain", content_type_charset=>"ascii", content_transfer_enc=>"8bit"));
                  $Hrl->Add(diversifEye::HttpRequest->new(method=>"$thisHttpOperation", uri=>"$thisHttpGetPath", content_type=>"multipart/form-data", content=>"$thisHttpPostContent", body_part_list=>$Bpl));
                }
                else {
                  $Hrl->Add(diversifEye::HttpRequest->new(method=>"$thisHttpOperation", uri=>"$thisHttpGetPath"));
                }
                $Tg->Add($Hrl);
              }

            }



          }
          $i = $i + 1;
        }
      }
    }
  }
}

if (($IgmpEnabled eq 1) && ($VERSION >= 11)) {
 ### Multicast Group List (IGMP).
  printf(STDERR "%s\n", 'Generating Multicast Group Lists ...');
  @IgmpAliasNames = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'IGMP'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_IGMP";
          }
          else {
            $Alias = $defaultIgmpAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@IgmpAliasNames) == 0) {
            push(@IgmpAliasNames, $AliasEntryName);

            $thisMulticastGroupAddrerss = "";
            if (defined $thisKey->[$i]->{'Multicast_Group_Addrerss'}) {
              $thisMulticastGroupAddrerss = $thisKey->[$i]->{'Multicast_Group_Addrerss'};
            }

            $thisSourcePort = "";
            if (defined $thisKey->[$i]->{'Source_Port'}) {
              $thisSourcePort = $thisKey->[$i]->{'Source_Port'};
            }

            $thisDestinationPort = "";
            if (defined $thisKey->[$i]->{'Destination_Port'}) {
              $thisDestinationPort = $thisKey->[$i]->{'Destination_Port'};
            }

            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) && ($thisMulticastGroupAddrerss ne "")){
                  $thisServerHostName = $thisKey->[$i]->{'Server_Host_Name'};
                  if (index($thisMulticastGroupAddrerss, ":") == -1) {
                    $Mgl = diversifEye::MulticastGroupList->new( name=>"Iggl".$thisServerHostName."_igmp", description=>"", ip_address_type=>"IPv4");
                  }
                  else {
                    $Mgl = diversifEye::MulticastGroupList->new( name=>"Iggl".$thisServerHostName."_igmp".$v6suffix, description=>"", ip_address_type=>"IPv6");
                  }
                  $Mgl->Add(diversifEye::MulticastGroup->new( group_address=>$thisMulticastGroupAddrerss, source_port=>$thisSourcePort, destination_port=>$thisDestinationPort) );
                  $Tg->Add($Mgl);
            }
          }
          $i = $i + 1;
        }
      }
    }
  }
}


if (($MldEnabled eq 1) && ($VERSION >= 11)) {
 ### Multicast Group List (MLD).
  @MldAliasNames = ();
  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if (defined $loadProfilesKey->{'MLD'}) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_MLD";
          }
          else {
            $Alias = $defaultMldAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@MldAliasNames) == 0) {
            push(@MldAliasNames, $AliasEntryName);

            $thisMulticastGroupAddrerss = "";
            if (defined $thisKey->[$i]->{'Multicast_Group_Addrerss'}) {
              $thisMulticastGroupAddrerss = $thisKey->[$i]->{'Multicast_Group_Addrerss'};
            }

            $thisSourcePort = "";
            if (defined $thisKey->[$i]->{'Source_Port'}) {
              $thisSourcePort = $thisKey->[$i]->{'Source_Port'};
            }

            $thisDestinationPort = "";
            if (defined $thisKey->[$i]->{'Destination_Port'}) {
              $thisDestinationPort = $thisKey->[$i]->{'Destination_Port'};
            }

            if ((defined $thisKey->[$i]->{'Server_Host_Name'}) && ($thisMulticastGroupAddrerss ne "")){
                  $thisServerHostName = $thisKey->[$i]->{'Server_Host_Name'};

                  if (index($thisMulticastGroupAddrerss, ":") == -1) {
                    $Mgl = diversifEye::MulticastGroupList->new( name=>"Iggl".$thisServerHostName."_mld", description=>"", ip_address_type=>"IPv4");
                  }
                  else {
                    $Mgl = diversifEye::MulticastGroupList->new( name=>"Iggl".$thisServerHostName."_mld".$v6suffix, description=>"", ip_address_type=>"IPv6");
                  }
                  $Mgl->Add(diversifEye::MulticastGroup->new( group_address=>$thisMulticastGroupAddrerss, source_port=>$thisSourcePort, destination_port=>$thisDestinationPort) );
                  $Tg->Add($Mgl);
            }
          }
          $i = $i + 1;
        }
      }
    }
  }
}




### Statistic Groups
if ($doStatisticGroups) {

  printf(STDERR "%s\n", 'Generating Statistic Groups ...');

  @FtpGetAliasNames = ();
  @FtpPutAliasNames = ();
  @HttpAliasNames = ();
  @VoipAliasNames = ();
  @RtspAliasNames = ();
  @TwampAliasNames = ();
  @VoIPApps = ();

  for ($profileId = -1; $profileId <= 9; $profileId++) {
    if ($profileId == -1) {
      $suffix = "";
      $profileName = "Default";
    }
    else {
      $suffix = "_P$profileId";
      $profileName = "Profile_$profileId";
    }

    if (defined $ClientProfilesKey->{$profileName} ) {
      $loadProfilesKey = $ClientProfilesKey->{$profileName};

      if ((defined $loadProfilesKey->{'FTP_Get'}) && ($FtpGetEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultFtpGetAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultFtpGetAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Get_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@FtpGetAliasNames) == 0) {
              push(@FtpGetAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'false');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'FtpClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }


      if ((defined $loadProfilesKey->{'FTP_Put'}) && ($FtpPutEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultFtpPutAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultFtpPutAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Put_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@FtpPutAliasNames) == 0) {
              push(@FtpPutAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'false');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'FtpClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }


      if ((defined $loadProfilesKey->{'HTTP'}) && ($HttpEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultHttpAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultHttpAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
              push(@HttpAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'false');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'HttpClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }



      if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {
        $thisKey = ();
        $nextKeyId = 0;

        if (defined $loadProfilesKey->{'VoIP'}) {
          $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
          if (!($thisKey =~ /ARRAY/)) {
            $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
          }
          foreach (@{$thisKey}) {
            $nextKeyId = $nextKeyId + 1;
          }
        }

        if (defined $loadProfilesKey->{'VoIMS'}) {
          $thisVoimsKey = ();
          $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
          if (!($thisVoimsKey =~ /ARRAY/)) {
            $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
          }
          $i = 0;
          foreach (@{$thisVoimsKey}) {
            $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
            $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
            $i = $i + 1;
            $nextKeyId = $nextKeyId + 1;
          }
        }
        $i = 0;

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultVoipAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultVoipAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VoIP_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
              push(@VoipAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {
                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);

                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }
                    $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                    if ((grep /^$host_name/,@VoIPApps) == 0) {  # only one VoIP type client per UE host
                      push(@VoIPApps, $host_name);

                      $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'true');
                      $Dag->Add(diversifEye::Aggregate->new(type=>'VoipUA', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                      $Tg->Add($Dag);
                    }
                  }
                }
              }
            }
          }
        }
      }



      if ((defined $loadProfilesKey->{'RTSP'}) && ($RtspEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultRtspAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultRtspAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
              push(@RtspAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'true');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'RtspClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }



      if ((defined $loadProfilesKey->{'TeraFlow'}) && ($TeraFlowEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultTeraFlowAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultTeraFlowAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_TF_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@TeraFlowAliasNames) == 0) {
              push(@TeraFlowAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'false');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'TeraFlowClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }


      if ((defined $loadProfilesKey->{'TWAMP'}) && ($TwampEnabled eq 1)) {
        $thisKey = ();
        $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'};
        $i = 0;

        if (!($thisKey =~ /ARRAY/)) {
          $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'}];
        }

        foreach (@{$thisKey}) {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
          }
          else {
            $Alias = $defaultTwampAlias;
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultTwampAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_TWAMP_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@TwampAliasNames) == 0) {
              push(@TwampAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

              }
              else {
                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                    if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }

                    $Dag = diversifEye::AggregateGroup->new(name=>$Alias."_".$base_name, rtp_statistics_enabled=>'false');
                    $Dag->Add(diversifEye::Aggregate->new(type=>'TwampClient', is_normal_stats_enabled=>$NormalStatsEnabled, is_fine_stats_enabled=>$FineStatsEnabled));
                    $Tg->Add($Dag);
                  }
                }
              }
            }
          }
        }
      }


    }
  }
}





my $Ps;

for $i (0..$#hconf)
{
  my $mac_addr = 'Ma'.$hconf[$i]{Card};

  ### DHCPv4 Configuration ###
  my $Do = diversifEye::Dhcp4Options->new();
  $Do->Set();
  $Do->Set('dhcp_parameter_request_list');
  $Do->Set('vendor_class_identifier', 'diversifEye 5.1');
  my $Dc = diversifEye::Dhcp4Config->new(dhcp_options=>$Do, offer_collection_timer=>'', rebinding_time=>'', lease_time=>'', renewal_time=>'');
    #my $Dc = diversifEye::Dhcp4Config->new(dhcp_options=>$Do);

  ### DHCPv6 Configuration ###
  my $D6o = diversifEye::Dhcp6Options->new();
  $D6o->Set();
  $D6o->Set('option_request');
  $D6o->Get('option_request')->
      Set('requested_option_codes', '1,6,22');
  $D6c = diversifEye::Dhcp6Config->new(dhcp_options=>$D6o);

  ### Global PPPoE Configuration ###
  my $Px = diversifEye::PppoeSettings->
  new(access_concentrator=>'', service_name=>'TestUk3',
  is_checking_host_uniq=>'false',
  is_pap_authentication_supported=>$conf{PPPOE_PAP},
  is_chap_authentication_supported=>$conf{PPPOE_CHAP},
  is_magic_number_used=>'false', is_double_retransmit_time=>'false',
  );

    if ($PooledConfig == 1) {
       $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$hconf[$i]{PooledPrefix}."-".$hconf[$i]{PooledUnit});
    }
    else {
       $thisPhysicalInterface = $hconf[$i]{Card}."/".$hconf[$i]{Port};
    }

    if ($hconf[$i]{Type} eq 'v4_EHost' && $hconf[$i]{HostName} eq 'v4_Client_GW' ) {
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v4_Client_GW_ip->addr,));
      $v4_Client_GW_ip->NextHost()->cidr();
    }
    if ($hconf[$i]{Type} eq 'v4_EHost' && $hconf[$i]{HostName} eq 'v4_Core_GW' ) {
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v4_Core_GW_ip->addr,));
      #$v4_Core_GW_ip->NextHost()->cidr();
    }
    elsif ($hconf[$i]{Type} eq 'v4_EHost') {
      if ($hconf[$i]{IP} ne "") {
        $thisGwIp = $hconf[$i]{IP};
      }
      else {
        $thisGwIp = $Gateway_ip->addr;
      }

      if ($VERSION >= 8.2) {
        $Tg->Add(diversifEye::ExternalHost->
        new(name=>$hconf[$i]{HostName},
        ip_address=>$thisGwIp));
      }
      else {
        $Tg->Add(diversifEye::ExternalHost->
        new(name=>$hconf[$i]{HostName},
        ip_address=>$Gateway_ip->addr,
        physical_interface=>$thisPhysicalInterface));
      }

      if ($hconf[$i]{IP} eq "") {
        $Gateway_ip->NextHost()->cidr();
      }
    }
    elsif ($hconf[$i]{Type} eq 'v6_EHost' && $hconf[$i]{HostName} eq 'v6_Client_GW' ) {
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v6_Client_GW_ip->addr));
      $v6_Client_GW_ip->NextHost()->cidr();
    }
    elsif ($hconf[$i]{Type} eq 'v6_EHost' && $hconf[$i]{HostName} eq 'v6_Core_GW' ) {
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v6_Core_GW_ip->addr));
      #$v6_Core_GW_ip->NextHost()->cidr();
    }
    elsif ($hconf[$i]{Type} eq 'v6_EHost') {
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v6_Gateway_ip->addr));
      $Gateway_ip->NextHost()->cidr();
    }


    elsif ($hconf[$i]{Type} eq 'v4_EServer') {
      $ip = diversifEye::IpAddress->new("$hconf[$i]{Addr}"."/".$ClientBits);
      if ($VERSION >= 8.2) {
        $Tg->Add(diversifEye::ExternalHost->
        new(name=>$hconf[$i]{HostName},
        ip_address=>$ip->addr))
      }
      else {
        $Tg->Add(diversifEye::ExternalHost->
        new(name=>$hconf[$i]{HostName},
        ip_address=>$ip->addr,
        physical_interface=>$thisPhysicalInterface))
      }
    }

    elsif ($hconf[$i]{Type} eq 'v6_EServer') {
      $v6_ip = diversifEye::IpAddress->new("$hconf[$i]{Addr}"."/".$v6_MaskBits);
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$v6_ip->addr));
    }

  $mac_addr = 'Ma'.$hconf[$i]{Card};

  if ($DiversifEyeType eq "TeraVM") { # Force TeraVM to use adapter default.
     $MacAssignmentMode = "Use MAC of Assigned Interface";
  }
  else {
     if (isMacObj($Ma{$mac_addr})) {
       $MacAssignmentMode = "Use Specific MAC Address";
     }
     else {
       $MacAssignmentMode = "Use MAC of Assigned Interface";
     }
  }

  ## Check for multiple entires.........

  if (($hconf[$i]{Type} eq 'v4_DVHS') || ($hconf[$i]{Type} eq 'v6_DVHS')) {

    if ($hconf[$i]{Application} eq 'PING') {
        if ($hconf[$i]{ServerIp} ne "") {
          $thisHostName = $hconf[$i]{HostName};
          if ($hconf[$i]{Type} eq 'v4_DVHS') {
            $thisIpAddress = diversifEye::IpAddress->new("$hconf[$i]{ServerIp}"."/".$MaskBits);
          }
          else {
            $thisIpAddress = diversifEye::IpAddress->new("$hconf[$i]{ServerIp}"."/".$v6_MaskBits);
          }

        }
        else {
          if ($hconf[$i]{Type} eq 'v4_DVHS') {
            $thisIpAddress = $Server_ip;
          }
          else {
            $thisIpAddress = $v6_Server_ip;
          }
        }

        foreach $key (keys %serverHosts) {
          if ($key ne $hconf[$i]{HostName}) {
            if ($serverHosts{$key} eq $serverHosts{$hconf[$i]{HostName}}) {
              $thisHostName = "Host_".$hconf[$i]{ServerIp};
              $thisHostName =~ s/:/-/g;
            }
          }
        }
    }
    else {
      if ($hconf[$i]{ServerIp} ne "") {
        if ($hconf[$i]{Type} eq 'v4_DVHS') {
          $thisIpAddress = diversifEye::IpAddress->new("$hconf[$i]{ServerIp}"."/".$MaskBits);
        }
        else {
          $thisIpAddress = diversifEye::IpAddress->new("$hconf[$i]{ServerIp}"."/".$v6_MaskBits);
        }
        $thisHostName = "Host_".$hconf[$i]{ServerIp};
        $thisHostName =~ s/:/-/g;
      }
      else {
        if ($hconf[$i]{Type} eq 'v4_DVHS') {
          $thisIpAddress = $Server_ip;
        }
        else {
          $thisIpAddress = $v6_Server_ip;
        }
        $thisHostName = $hconf[$i]{HostName};
      }
    }
    if ((grep /^$thisHostName/,@InternalHostNames) == 0) {
      if ($PooledConfig == 1) {
         $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$hconf[$i]{PooledPrefix}."-".$hconf[$i]{PooledUnit});
      }
      else {
         $thisPhysicalInterface = $hconf[$i]{Card}."/".$hconf[$i]{Port};
      }
      push(@InternalHostNames, $thisHostName);

      if (($useScaledEntities eq 1) && ($hconf[$i]{Application} eq 'PING')) {
#          $Tg->NewTemplate();
#          $Tg->Add(diversifEye::DirectVirtualHost->new(scale_factor=>$conf{UEs},
#          name=>diversifEye::PsAlnum->new(prefix_label=>$thisHostName),
#          ip_address=>$thisIpAddress,
#          mac_address_assignment_mode=>"Auto Generate MAC From Base Value",
#          mac_address=>$Ma{$mac_addr},
#          gateway_host=>$hconf[$i]{GatewayName},
#          mtu=>'1500',
#          vlan_id_outer=>$hconf[$i]{VLAN_TAG},
#          physical_interface=>$thisPhysicalInterface));
#          $Tg->NewTemplate();
#
#          $Ma{$mac_addr} += $conf{UEs};
      }
      else {
        $Tg->NewTemplate();
        $Tg->Add(diversifEye::DirectVirtualHost->
        new(name=>$thisHostName,
        ip_address=>$thisIpAddress,
        mac_address_assignment_mode=>$MacAssignmentMode,
        mac_address=>$Ma{$mac_addr},
        gateway_host=>$hconf[$i]{GatewayName},
        mtu=>'1500',
        vlan_id_outer=>$hconf[$i]{VLAN_TAG},
        physical_interface=>$thisPhysicalInterface));

        if ($hconf[$i]{ServerIp} eq "") {
          if ($hconf[$i]{Type} eq 'v4_DVHS') {
            $Server_ip->NextHost()->cidr();
          }
          else {
            $v6_Server_ip->NextHost()->cidr();
          }
        }
      }
    }
  }

  # Ensure template is a "client" host.
  if ($PooledConfig == 1) {
     $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$hconf[$i]{PooledPrefix}."-".$hconf[$i]{PooledUnit});
  }
  else {
     $thisPhysicalInterface = $hconf[$i]{Card}."/".$hconf[$i]{Port};
  }

  if ($hconf[$i]{Type} eq 'v4_DVH') {

    if ($conf{addr_assignment} eq 'DHCP') {
      $Tg->NewTemplate();
      for $x (1..$hconf[$i]{Number}) {
        $Tg->Add(diversifEye::DirectVirtualHost->
        new(name=>$hconf[$i]{HostName}."_RG".sprintf("%05s", $x),
        ip_assignment_type=>"DHCPv4",
        dhcp_configuration=>$Dc,
        mac_address_assignment_mode=>$MacAssignmentMode,
        mac_address=>$Ma{$mac_addr},
        mtu=>'1496',
        vlan_id_outer=>$hconf[$i]{VLAN_TAG},
        physical_interface=>$thisPhysicalInterface));
        $Client_ip->NextHost()->cidr();
        if (isMacObj($Ma{mac_addr})) {
          $Ma{$mac_addr}++;
        }
      }
    }

    elsif ($conf{addr_assignment} eq 'PPPoE') {
      $Tg->NewTemplate();
      for $x (1..$hconf[$i]{Number}) {
        $Ps = diversifEye::PppoeSettings->
        new(access_concentrator=>'', service_name=>$hconf[$i]{Outer},
        is_checking_host_uniq=>'false',
        is_pap_authentication_supported=>$conf{PPPOE_PAP},
        is_chap_authentication_supported=>$conf{PPPOE_CHAP},
        is_magic_number_used=>'false', is_double_retransmit_time=>'false',
        );

        $Tg->Add(diversifEye::DirectVirtualHost->
        new(name=>$hconf[$i]{HostName}."_RG".sprintf("%05s", $x),
        ip_assignment_type=>"PPPoE/IPv4CP",
        pppoe_settings=>$Ps,
        mac_address_assignment_mode=>$MacAssignmentMode,
        mac_address=>$Ma{$mac_addr},
        mtu=>'1492',
        vlan_id_outer=>$hconf[$i]{VLAN_TAG},
        physical_interface=>$thisPhysicalInterface,
        host_fine_stats_enabled=>"false",
        ));
        $Client_ip->NextHost()->cidr();
        if (isMacObj($Ma{mac_addr})) {
          $Ma{$mac_addr}++;
        }
      }
    }

    elsif ($conf{addr_assignment} eq 'Static') {
      $Tg->NewTemplate();
      for $x (1..$hconf[$i]{Number}) {
        $Tg->Add(diversifEye::DirectVirtualHost->
        new(name=>$hconf[$i]{HostName}."_RG".sprintf("%05s", $x),
        ip_address=>$Client_ip,
        mac_address_assignment_mode=>$MacAssignmentMode,
        mac_address=>$Ma{$mac_addr},
        gateway_host=>$hconf[$i]{GatewayName},
        mtu=>'1500',
        vlan_id_outer=>$hconf[$i]{VLAN_TAG},
        physical_interface=>$thisPhysicalInterface));
        $Client_ip->NextHost()->cidr();
        if (isMacObj($Ma{mac_addr})) {
          $Ma{$mac_addr}++;
        }
      }
    }

  }
  elsif ($hconf[$i]{Type} eq 'CSH') {
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::DirectVirtualSubnetHost->
    new(name=>$hconf[$i]{HostName},
    ip_address=>$Client_subnet_ip,
    mac_address_assignment_mode=>$MacAssignmentMode,
    mac_address=>$Ma{$mac_addr},
    gateway_host=>$hconf[$i]{GatewayName},
    mtu=>'1500',
    vlan_id_outer=>$hconf[$i]{VLAN_TAG},
    physical_interface=>$thisPhysicalInterface));
    $Client_subnet_ip->NextSubnet();
  }
  elsif ($hconf[$i]{Type} eq 'v4_EHost') {
    if (lc($hconf[$i]{Location}) eq "core") {
      $thisGatewayIp = $v4_Core_GW_ip->addr;
      $thisGatewayName = "v4_Core_GW";
      #$v4_Core_GW_ip->NextHost()->cidr();
    }
    else {
      if ($hconf[$i]{IP} ne "") {
        $thisGatewayIp = $hconf[$i]{IP};
        $thisGatewayName = $hconf[$i]{GatewayName};
      }
      else {
        $thisGatewayIp = $Gateway_ip->addr;
        $thisGatewayName = $hconf[$i]{GatewayName};
        $Gateway_ip->NextHost()->cidr();
      }

    }

    if ($VERSION >= 8.2) {
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$thisGatewayIp));
    }
    else {
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalHost->
      new(name=>$hconf[$i]{HostName},
      ip_address=>$thisGatewayIp,
      mac_address_assignment_mode=>$MacAssignmentMode,
      mac_address=>$Ma{$mac_addr},
      gateway_host=>$thisGatewayName,
      mtu=>'1500',
      vlan_id_outer=>$hconf[$i]{VLAN_TAG},
      physical_interface=>$thisPhysicalInterface));
    }
  }
  if (isMacObj($Ma{$mac_addr})) {
    $Ma{$mac_addr}++;
  }
}


### Now Create the per-UE, per-PDN PPPoE clients (based on the template) - and associated application clients
my $pppoe_mac = "";
my $pppoe_card_mac_addr = "";

my $tmpmKey = None;
if ($DiversifEyeType eq "1000") {
  if (defined $xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'}) {
    $tmpmKey = $xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'};

    if (!($tmpmKey =~ /ARRAY/)) {
      $tmpmKey = [$xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'}];
    }

    $ueRangesKey = ();

    for $pdn (0..$PDNs_per_UE-1) {
      $ueRangesKey->[$pdn] = "";
      $i = 0;
      foreach (@{$tmpmKey}) {
        $UeRange = "";
        $PdnRange = "";
        $inPdnRange = 0;
        if (defined $tmpmKey->[$i]->{'UE'}) {
          $UeRange = $tmpmKey->[$i]->{'UE'};
        }

        if (defined $tmpmKey->[$i]->{'PDN'}) {
          $PdnRange = $tmpmKey->[$i]->{'PDN'};
        }

        if ($PdnRange eq "") {
          $inPdnRange = 1;
        }
        elsif ($PdnRange ne "") {
          if ((isInRange($pdn, $PdnRange) == 1)) {
            $inPdnRange = 1;
          }
        }

        if ($inPdnRange == 1) {
          if ($UeRange eq "") {
            $halfUEs = floor(($conf{UEs}-1)/2);
            $ueRangesKey->[$pdn] = "0..".$halfUEs.",".($halfUEs+1)."..".($conf{UEs}-1);
          }
          else {
            if ($ueRangesKey->[$pdn] eq "") {
              $ueRangesKey->[$pdn] = $ueRangesKey->[$pdn] . $UeRange;
            }
            else {
              $ueRangesKey->[$pdn] = $ueRangesKey->[$pdn] . "," . $UeRange;
            }
          }
        }
        $i = $i + 1;
      }
      if ($ueRangesKey->[$pdn] eq "") {
        $halfUEs = floor(($conf{UEs}-1)/2);
        $ueRangesKey->[$pdn] = "0..".$halfUEs.",".($halfUEs+1)."..".($conf{UEs}-1);
      }
    }

    $nextTmpmKeyIndex = $i;

    for $pdn (0..$PDNs_per_UE-1) {
      $lastMin = -1;
      $lastMax = -1;
      $halfUEs = floor(($conf{UEs}-1)/2);
      $thisPPPoECard = $conf{PPPOE_CARD};

      for $ue (0..$conf{UEs}-1) {
        if (isInRange($ue, $ueRangesKey->[$pdn]) == 0) {
          if ($lastMin == -1) {
            $lastMin = $ue;
          }

          if (($ue > $lastMax) and ($lastMin != -1)) {
            $lastMax = $ue;
          }

          # Split on half max UE boundary.
          if (($lastMin < $halfUEs) and ($ue > $halfUEs)) {
            if ($lastMin == $lastMax) {
              $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
              $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "0";
              $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
              $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;

            }
            else {
              $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$halfUEs;
              $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard + 20;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "1";
              $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
              $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;

              $lastMin = -1;
            }

            $lastMin = $halfUEs + 1;
            $lastMax = $ue;
          }

        }
        else {
          # we have matched so need to commit values.
          if ($lastMin != -1) {
            if ($lastMin == $lastMax) {
              if ($lastMin < $halfUEs) {
                $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
                $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "0";
                $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
                $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              }
              else {
                $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
                $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard + 20;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "1";
                $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
                $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              }

              $lastMin = -1;
            }
            else {
              if ($lastMin < $halfUEs) {
                $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
                $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "0";
                $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
                $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              }
              else {
                $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
                $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard + 20;
                $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "1";
                $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
                $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              }
              $lastMin = -1;
            }
          }
        }
      }

      if ($lastMin != -1) {
        if ($lastMin == $lastMax) {
          push (@missingRanges, $lastMin);
          if ($lastMin < $halfUEs) {
            $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
            $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "0";
            $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
            $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          }
          else {
            $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
            $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard + 20;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "1";
            $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
            $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          }
          $lastMin = -1;
        }
        else {
          push (@missingRanges, $lastMin."..".$lastMax);
          if ($lastMin < $halfUEs) {
            $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
            $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "0";
            $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
            $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          }
          else {
            $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
            $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard + 20;
            $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = "1";
            $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
            $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          }
          $lastMin = -1;
        }
      }
    }
  }
  else {  # Create the defaults for the d1000
    $halfUEs = floor(($conf{UEs}-1)/2);
    $thisPPPoECard = $conf{PPPOE_CARD};
    $tmpmKey = ();
    $tmpmKey->[0]->{'UE'} = "0..".$halfUEs;
    $tmpmKey->[0]->{'Test_Module_Number'} = $thisPPPoECard;
    $tmpmKey->[0]->{'Test_Interface'} = "0";
    $tmpmKey->[0]->{'Pooled_Unit'} = 1;
    $tmpmKey->[1]->{'UE'} = ($halfUEs+1)."..";
    $tmpmKey->[1]->{'Test_Module_Number'} = $thisPPPoECard + 20;
    $tmpmKey->[1]->{'Test_Interface'} = "1";
    $tmpmKey->[1]->{'Pooled_Unit'} = 2;
  }
}
elsif ($DiversifEyeType eq "TeraVM") {
  if (defined $xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'}) {
    $tmpmKey = $xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'};

    if (!($tmpmKey =~ /ARRAY/)) {
      $tmpmKey = [$xmlHash->{'diversifEye_Configuration'}->{'TM500'}->{'Test_Module_Port_Mapping'}];
    }

    $ueRangesKey = ();

    for $pdn (0..$PDNs_per_UE-1) {
      $ueRangesKey->[$pdn] = "";
      $i = 0;
      foreach (@{$tmpmKey}) {
        $UeRange = "";
        $PdnRange = "";
        $inPdnRange = 0;
        if (defined $tmpmKey->[$i]->{'UE'}) {
          $UeRange = $tmpmKey->[$i]->{'UE'};
        }

        if (defined $tmpmKey->[$i]->{'PDN'}) {
          $PdnRange = $tmpmKey->[$i]->{'PDN'};
        }

        if ($PdnRange eq "") {
          $inPdnRange = 1;
        }
        elsif ($PdnRange ne "") {
          if ((isInRange($pdn, $PdnRange) == 1)) {
            $inPdnRange = 1;
          }
        }

        if ($inPdnRange == 1) {
          if ($UeRange eq "") {
            $ueRangesKey->[$pdn] = "0..".($conf{UEs}-1);
          }
          else {
            if ($ueRangesKey->[$pdn] eq "") {
              $ueRangesKey->[$pdn] = $ueRangesKey->[$pdn] . $UeRange;
            }
            else {
              $ueRangesKey->[$pdn] = $ueRangesKey->[$pdn] . "," . $UeRange;
            }
          }
        }
        $i = $i + 1;
      }
      if ($ueRangesKey->[$pdn] eq "") {
        $ueRangesKey->[$pdn] = "0..".($conf{UEs}-1);
      }
    }

    $nextTmpmKeyIndex = $i;

    for $pdn (0..$PDNs_per_UE-1) {
      $lastMin = -1;
      $lastMax = -1;
      $thisPPPoECard = $conf{PPPOE_CARD};

      for $ue (0..$conf{UEs}-1) {
        if (isInRange($ue, $ueRangesKey->[$pdn]) == 0) {
          if ($lastMin == -1) {
            $lastMin = $ue;
          }

          if (($ue > $lastMax) and ($lastMin != -1)) {
            $lastMax = $ue;
          }
        }
        else {
          # we have matched so need to commit values.
          if ($lastMin != -1) {
            if ($lastMin == $lastMax) {
              $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
              $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
              $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              $lastMin = -1;
            }
            else {
              $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
              $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
              $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
              $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
              $lastMin = -1;
            }
          }
        }
      }

      if ($lastMin != -1) {
        if ($lastMin == $lastMax) {
          push (@missingRanges, $lastMin);
          $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin;
          $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 1;
          $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          $lastMin = -1;
        }
        else {
          push (@missingRanges, $lastMin."..".$lastMax);
          $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $lastMin."..".$lastMax;
          $tmpmKey->[$nextTmpmKeyIndex]->{'PDN'} = $pdn;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = 2;
          $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          $lastMin = -1;
        }
      }
    }
  }
  else {  # Split in to MAX of 6000 UEs
    $thisPPPoECard = $conf{PPPOE_CARD};
    $allUEs = $conf{UEs};
    $tmpmKey = ();
    $nextTmpmKeyIndex = 0;
    if ($VERSION >= 12) {
        $TeraVM_MaxUes_per_tm = ceil($allUEs / $ProcessingMaxUnits);
    }
    $loops = floor($allUEs / $TeraVM_MaxUes_per_tm);
    $extras = $allUEs - ($loops * $TeraVM_MaxUes_per_tm);
    $initialUe = 0;
    $thisPooledUnit = 1;

    if ($loops > 0) {
       for ($count = 0; $count < $loops; $count++) {
          $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $initialUe."..".((($count+1) * $TeraVM_MaxUes_per_tm)-1);
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} =  $thisPPPoECard;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
          $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = $thisPooledUnit;
          $nextTmpmKeyIndex = $nextTmpmKeyIndex + 1;
          $thisPPPoECard = $thisPPPoECard + 1;
          $thisPooledUnit = $thisPooledUnit + 1;
          $initialUe = ($count+1) * $TeraVM_MaxUes_per_tm;
       }
    }

    if ($extras > 0) {
      $tmpmKey->[$nextTmpmKeyIndex]->{'UE'} = $initialUe."..".($initialUe+($extras-1));
      $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Module_Number'} = $thisPPPoECard;
      $tmpmKey->[$nextTmpmKeyIndex]->{'Test_Interface'} = $TeraVM_Client_IF;
      $tmpmKey->[$nextTmpmKeyIndex]->{'Pooled_Unit'} = $thisPooledUnit;
    }
  }
}


if ($useScaledEntities eq 1) {

  printf(STDERR "%s\n", 'Generating PPPoE Hosts ...');

  if ($DiversifEyeType eq "TeraVM") { # Force TeraVM to use adapter default.
     $pppoe_mac = "";
     $MacAssignmentMode = "Use MAC of Assigned Interface";
  }
  else {
     if ($conf{PPPOE_MAC_START} ne "") {
       $pppoe_mac = diversifEye::PsMac->new(start_mac_address=>$conf{PPPOE_MAC_START});
       $MacAssignmentMode = "Auto Generate MAC From Base Value";
     }
     elsif (isMacObj($Ma{$pppoe_card_mac_addr})) {
       $pppoe_mac = diversifEye::PsMac->new(start_mac_address=>$Ma{$pppoe_card_mac_addr});
       $MacAssignmentMode = "Auto Generate MAC From Base Value";
     }
     else {
       $pppoe_mac = "";
       $MacAssignmentMode = "Use MAC of Assigned Interface";
     }
  }


  for $pdn (0..$PDNs_per_UE-1) {
    # IPv4 Hosts
    $Ps = diversifEye::PppoeSettings->
      new(service_name=>diversifEye::PsAlnum->new(prefix_label=>$service_name_prefix, suffix_label=>"_".$pdn, starting_at=>0,  increment_size=>1),
      is_pap_authentication_supported=>$conf{PPPOE_PAP},
      is_chap_authentication_supported=>$conf{PPPOE_CHAP}
    );

    $Ps6 = diversifEye::PppoeSettings->
       new(service_name=>diversifEye::PsAlnum->new(prefix_label=>$service_name_prefix, suffix_label=>"_".$pdn, starting_at=>0,  increment_size=>1),
       is_pap_authentication_supported=>$conf{PPPOE_PAP},
       is_chap_authentication_supported=>$conf{PPPOE_CHAP},
       request_primary_dns_server_address=>'true',
       request_secondary_dns_server_address=>'true',
       for_ipv6=>'true'
    );

    $D6o = diversifEye::Dhcp6Options->new();
    $D6o->Set();
    $D6c = diversifEye::Dhcp6Config->new(dhcp_options=>$D6o);


    if ($PooledConfig == 1) {
       $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$conf{PPPOE_POOLED_PREFIX}."-".$conf{PPPOE_POOLED_UNIT});
    }
    else {
       $thisPhysicalInterface = $conf{PPPOE_CARD}."/".$conf{PPPOE_PORT};
    }
    if ($VERSION >= 12.0) {
        if ((grep /^$conf{PPPOE_CARD}/,@PARTITION_INTERFACES) == 0) {
          push(@PARTITION_INTERFACES,$conf{PPPOE_CARD});
        }
    }

    if ((($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) && ($tmpmKey ne None)) {
      $i = 0;
      $pppoeGroupList[$pdn] = "";
      foreach (@{$tmpmKey}) {
        $UeRange = "";
        $PdnRange = "";
        if (defined $tmpmKey->[$i]->{'UE'}) {
          $UeRange = $tmpmKey->[$i]->{'UE'};
        }

        if (defined $tmpmKey->[$i]->{'PDN'}) {
          $PdnRange = $tmpmKey->[$i]->{'PDN'};
        }

        $rangeStr = cleanRange($UeRange, $PdnRange);

        # Here we need to create the groups based on the Test Module configuration
        $thisTempPPPoECard = $conf{PPPOE_CARD};
        $thisTempPPPoEPort = $conf{PPPOE_PORT};

        if (defined $tmpmKey->[$i]->{'Test_Module_Offset'}) {
          $thisTempPPPoECard = $conf{PPPOE_CARD} + $tmpmKey->[$i]->{'Test_Module_Offset'};
        }

        if (defined $tmpmKey->[$i]->{'Test_Module_Number'}) {
          $thisTempPPPoECard = $tmpmKey->[$i]->{'Test_Module_Number'};
        }

        if (defined $tmpmKey->[$i]->{'Test_Interface'}) {
          $thisTempPPPoEPort = $tmpmKey->[$i]->{'Test_Interface'};
        }

        $thisTempPooledUnit = 1;
        if (defined $tmpmKey->[$i]->{'Pooled_Unit'}) {
          $thisTempPooledUnit = $tmpmKey->[$i]->{'Pooled_Unit'};
        }

        if ($PooledConfig == 1) {
           $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$PooledUePrefix."-".$thisTempPooledUnit);
        }
        else {
           $thisPhysicalInterface = $thisTempPPPoECard."/".$portPrefix.$thisTempPPPoEPort;
        }

        $createPdnEntry = 0;
        if ($PdnRange eq "") {
          $createPdnEntry = 1;
        }
        elsif ($PdnRange ne "") {
          if ((isInRange($pdn, $PdnRange) == 1)) {
            $createPdnEntry = 1;
          }
        }

        if ($createPdnEntry eq 1) {
          if ($UeRange eq "") {
            $UeRange = "0..".($conf{UEs}-1);
          }

          @UeGroups = ();
          if (index($UeRange, ",") != -1) {
            @UeGroups = split(",", $UeRange);
          }
          else {
            push(@UeGroups, $UeRange);
          }

          foreach $thisUeRange (@UeGroups) {
            $mtmoStr = "";
            $oddOrEvenOrNone = "all";

            $thisUeRange =~ s/-/\.\./g;
            if ($thisUeRange =~ m/\.\./) {
              ($minVal, $maxVal) = split('\.\.', $thisUeRange);
            }
            else {
              $maxVal = $thisUeRange;
            }

            if ($pppoeGroupList[$pdn] eq "") {
                if ($maxVal eq "") { # for the case "x.."
                  $pppoeGroupList[$pdn] = $thisUeRange.($conf{UEs}-1);
                }
                else {
                  $pppoeGroupList[$pdn] = $thisUeRange;
                }
            }
            else {
              if ($maxVal eq "") { # for the case "x.."
                $pppoeGroupList[$pdn] = $pppoeGroupList[$pdn] . "," . $thisUeRange.($conf{UEs}-1);
              }
              else {
                $pppoeGroupList[$pdn] = $pppoeGroupList[$pdn] . "," . $thisUeRange;
              }
            }

            ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn, $mtmoStr);

            $Tg->NewTemplate();

            $Ps = diversifEye::PppoeSettings->
              new(service_name=>diversifEye::PsAlnum->new(prefix_label=>$service_name_prefix, suffix_label=>"_".$pdn, starting_at=>$startingAt,  increment_size=>$incrementSize),
              is_pap_authentication_supported=>$conf{PPPOE_PAP},
              is_chap_authentication_supported=>$conf{PPPOE_CHAP}
            );

            $Tg->Add(diversifEye::DirectVirtualHost->new(scale_factor=>$scaleFactor,
             name=>diversifEye::PsAlnum->new(prefix_label=>"pppoe_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>"pppoe_".$overrideName),
             ip_assignment_type=>"PPPoE/IPv4CP",
             pppoe_settings=>$Ps,
             mac_address=>$pppoe_mac,
             mac_address_assignment_mode=>$MacAssignmentMode,
             mtu=>$conf{PPPOE_MTU},
             vlan_id_outer=>$conf{VLAN_TAG},
             physical_interface=>$thisPhysicalInterface,
             host_fine_stats_enabled=>"false",
             tcp_characteristics=>$TcpCharacteristicsDefault,
             service_state=>$ServiceState
             ));

            # IPv6 Hosts
            $Tg->NewTemplate();

            $Ps6 = diversifEye::PppoeSettings->
               new(service_name=>diversifEye::PsAlnum->new(prefix_label=>$service_name_prefix, suffix_label=>"_".$pdn, starting_at=>$startingAt,  increment_size=>$incrementSize),
               is_pap_authentication_supported=>$conf{PPPOE_PAP},
               is_chap_authentication_supported=>$conf{PPPOE_CHAP},
               request_primary_dns_server_address=>'true',
               request_secondary_dns_server_address=>'true',
               for_ipv6=>'true'
            );

            $Tg->Add(diversifEye::DirectVirtualHost->new(scale_factor=>$scaleFactor,
              name=>diversifEye::PsAlnum->new(prefix_label=>"pppoe6_", suffix_label=>"_".$pdn, starting_at=>$startingAt,  increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>"pppoe6_".$overrideName),
              ip_address=>'::',
              ip_assignment_type=>"DHCPv6",
              pppoe_settings=>$Ps6,
              mac_address=>$pppoe_mac,
              mac_address_assignment_mode=>$MacAssignmentMode,
              mtu=>$conf{PPPOE_MTU},
              vlan_id_outer=>$conf{VLAN_TAG},
              physical_interface=>$thisPhysicalInterface,
              host_fine_stats_enabled=>"false",
              tcp_characteristics=>$TcpCharacteristicsDefault,
              dhcp_configuration=>$D6c,
              service_state=>$ServiceState
              ));
          }
        }
        $i = $i + 1;
      }
    }
    else {
      $Tg->NewTemplate();

      $Tg->Add(diversifEye::DirectVirtualHost->new(scale_factor=>$conf{UEs},
       name=>diversifEye::PsAlnum->new(prefix_label=>"pppoe_", suffix_label=>"_".$pdn, starting_at=>0,  increment_size=>1, padding_enabled=>$useScaledPadding, value_override=>"pppoe_".$pdn),
       ip_assignment_type=>"PPPoE/IPv4CP",
       pppoe_settings=>$Ps,
       mac_address=>$pppoe_mac,
       mac_address_assignment_mode=>$MacAssignmentMode,
       mtu=>$conf{PPPOE_MTU},
       vlan_id_outer=>$conf{VLAN_TAG},
       physical_interface=>$thisPhysicalInterface,
       host_fine_stats_enabled=>"false",
       tcp_characteristics=>$TcpCharacteristicsDefault,
       service_state=>$ServiceState
       ));

      $Tg->NewTemplate();

      $Tg->Add(diversifEye::DirectVirtualHost->new(scale_factor=>$conf{UEs},
        name=>diversifEye::PsAlnum->new(prefix_label=>"pppoe6_", suffix_label=>"_".$pdn, starting_at=>0,  increment_size=>1, padding_enabled=>$useScaledPadding, value_override=>"pppoe6_".$pdn),
        ip_address=>'::',
        ip_assignment_type=>"DHCPv6",
        pppoe_settings=>$Ps6,
        mac_address=>$pppoe_mac,
        mac_address_assignment_mode=>$MacAssignmentMode,
        mtu=>$conf{PPPOE_MTU},
        vlan_id_outer=>$conf{VLAN_TAG},
        physical_interface=>$thisPhysicalInterface,
        host_fine_stats_enabled=>"false",
        tcp_characteristics=>$TcpCharacteristicsDefault,
        dhcp_configuration=>$D6c,
        service_state=>$ServiceState
        ));
    }

  }
}
else {
  printf(STDERR "%s\n", 'Generating PPPoE Hosts per UE per PDN ...');

  $pppoe_card_mac_addr = 'Ma'.$conf{PPPOE_CARD};

  if ($DiversifEyeType eq "TeraVM") { # Force TeraVM to use adapter default.
     $pppoe_mac = "";
     $MacAssignmentMode = "Use MAC of Assigned Interface";
  }
  else {
     if ($conf{PPPOE_MAC_START} ne "") {
       $pppoe_mac = diversifEye::Mac->new($conf{PPPOE_MAC_START});
       $MacAssignmentMode = "Use Specific MAC Address";
     }
     elsif (isMacObj($Ma{$pppoe_card_mac_addr})) {
       $pppoe_mac = $Ma{$pppoe_card_mac_addr};
       $MacAssignmentMode = "Use Specific MAC Address";
     }
     else {
       $pppoe_mac = "";
       $MacAssignmentMode = "Use MAC of Assigned Interface";
     }
  }

  for $ue (0..$conf{UEs}-1) {
    for $pdn (0..$PDNs_per_UE-1) {
      $service_name = $service_name_prefix . $ue . "_" . $pdn;
      $base_name = sprintf("%0${MinimumUeIdDigits}s", $ue)."_".sprintf("%s", $pdn);
      $host_name = "pppoe_".$base_name;

      $Tg->NewTemplate();

      $createIPv6Entry = 0;
      if ($PPPoEIPv6Enabled eq 1) {
        if (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange eq "")) {
          $createIPv6Entry = 1;
        }
        elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange ne "")) {
          if ((isInRange($ue, $PPPoEIPv6UeRange) == 1) && (isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
            $createIPv6Entry = 1;
          }
        }
        elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange eq "")) {
          if ((isInRange($ue, $PPPoEIPv6UeRange) == 1)) {
            $createIPv6Entry = 1;
          }
        }
        elsif (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange ne "")) {
          if ((isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
            $createIPv6Entry = 1;
          }
        }
      }

      $thisPhysicalInterface = $conf{PPPOE_CARD}."/".$conf{PPPOE_PORT};
      if ($VERSION >= 12.0) {
        if ((grep /^$conf{PPPOE_CARD}/,@PARTITION_INTERFACES) == 0) {
          push(@PARTITION_INTERFACES, $conf{PPPOE_CARD});
        }
      }

      if ((($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) && ($tmpmKey ne None)) {
        $i = 0;
        foreach (@{$tmpmKey}) {
          $UeRange = "";
          $PdnRange = "";
          if (defined $tmpmKey->[$i]->{'UE'}) {
            $UeRange = $tmpmKey->[$i]->{'UE'};
          }

          if (defined $tmpmKey->[$i]->{'PDN'}) {
            $PdnRange = $tmpmKey->[$i]->{'PDN'};
          }

          $thisTempPPPoECard = $conf{PPPOE_CARD};
          $thisTempPPPoEPort = $conf{PPPOE_PORT};

          if (defined $tmpmKey->[$i]->{'Test_Module_Offset'}) {
            $thisTempPPPoECard = $conf{PPPOE_CARD} + $tmpmKey->[$i]->{'Test_Module_Offset'};
          }

          if (defined $tmpmKey->[$i]->{'Test_Module_Number'}) {
            $thisTempPPPoECard = $tmpmKey->[$i]->{'Test_Module_Number'};
          }

          if (defined $tmpmKey->[$i]->{'Test_Interface'}) {
            $thisTempPPPoEPort = $tmpmKey->[$i]->{'Test_Interface'};
          }

          $thisTempPooledUnit = 1;
          if (defined $tmpmKey->[$i]->{'Pooled_Unit'}) {
            $thisTempPooledUnit = $tmpmKey->[$i]->{'Pooled_Unit'};
          }

          if (($UeRange eq "") && ($PdnRange eq "")) {
            if ($PooledConfig == 1) {
               $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$PooledUePrefix."-".$thisTempPooledUnit);
            }
            else {
               $thisPhysicalInterface = $thisTempPPPoECard."/".$portPrefix.$thisTempPPPoEPort;
            }
            last;
          }
          elsif (($UeRange ne "") && ($PdnRange ne "")) {
            if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
              if ($PooledConfig == 1) {
                 $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$PooledUePrefix."-".$thisTempPooledUnit);
              }
              else {
                 $thisPhysicalInterface = $thisTempPPPoECard."/".$portPrefix.$portPrefix.$thisTempPPPoEPort;
              }
              last;
            }
          }
          elsif (($UeRange ne "") && ($PdnRange eq "")) {
            if ((isInRange($ue, $UeRange) == 1)) {
              if ($PooledConfig == 1) {
                 $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$PooledUePrefix."-".$thisTempPooledUnit);
              }
              else {
                 $thisPhysicalInterface = $thisTempPPPoECard."/".$portPrefix.$thisTempPPPoEPort;
              }
              last;
            }
          }
          elsif (($UeRange eq "") && ($PdnRange ne "")) {
            if ((isInRange($pdn, $PdnRange) == 1)) {
              if ($PooledConfig == 1) {
                 $thisPhysicalInterface = diversifEye::PsIfl->new(values=>$PooledUePrefix."-".$thisTempPooledUnit);
              }
              else {
                 $thisPhysicalInterface = $thisTempPPPoECard."/".$portPrefix.$thisTempPPPoEPort;
              }
              last;
            }
          }
          $i = $i + 1;
        }
      }

      if ($createIPv6Entry eq 1) {
        # We are doing a IPv6 conection
        ###### Local (Unique per host) PPPoE Configuration ####
        $Ps = diversifEye::PppoeSettings->
        new(service_name=>$service_name,
        is_pap_authentication_supported=>$conf{PPPOE_PAP},
        is_chap_authentication_supported=>$conf{PPPOE_CHAP},
        request_primary_dns_server_address=>'true',
        request_secondary_dns_server_address=>'true',
        for_ipv6=>'true'
        );

        $D6o = diversifEye::Dhcp6Options->new();
        $D6o->Set();
        $D6c = diversifEye::Dhcp6Config->new(dhcp_options=>$D6o);

        if ($VERSION <= 7.5) {
          $Tg->Add(diversifEye::DirectVirtualHost->
          new(name=>$host_name,
          ip_address=>'::',
          ip_assignment_type=>"DHCPv6",
          pppoe_settings=>$Ps,
          mac_address=>$pppoe_mac,
          mtu=>$conf{PPPOE_MTU},
          vlan_id_outer=>$conf{VLAN_TAG},
          physical_interface=>$thisPhysicalInterface,
          host_fine_stats_enabled=>"false",
          tcp_characteristics=>$TcpCharacteristicsDefault,
          dhcp_configuration=>$D6c,
          service_state=>$ServiceState));
        }
        else {
          $Tg->Add(diversifEye::DirectVirtualHost->
          new(name=>$host_name,
          ip_address=>'::',
          ip_assignment_type=>"DHCPv6",
          pppoe_settings=>$Ps,
          mac_address_assignment_mode=>$MacAssignmentMode,
          mac_address=>$pppoe_mac,
          mtu=>$conf{PPPOE_MTU},
          vlan_id_outer=>$conf{VLAN_TAG},
          physical_interface=>$thisPhysicalInterface,
          host_fine_stats_enabled=>"false",
          tcp_characteristics=>$TcpCharacteristicsDefault,
          dhcp_configuration=>$D6c,
          service_state=>$ServiceState));
        }

        if ($conf{PPPOE_MAC_START} ne "") {
          $pppoe_mac++;
        }
        elsif (isMacObj($Ma{$pppoe_card_mac_addr})) {
          $Ma{$pppoe_card_mac_addr}++;
          $pppoe_mac = $Ma{$pppoe_card_mac_addr};
        }
      }
      else {
        ###### Local (Unique per host) PPPoE Configuration ####
        $Ps = diversifEye::PppoeSettings->
        new(service_name=>$service_name,
        is_pap_authentication_supported=>$conf{PPPOE_PAP},
        is_chap_authentication_supported=>$conf{PPPOE_CHAP});

        if ($VERSION <= 7.5) {
          $Tg->Add(diversifEye::DirectVirtualHost->
          new(name=>$host_name,
          ip_assignment_type=>"PPPoE/IPv4CP",
          pppoe_settings=>$Ps,
          mac_address=>$pppoe_mac,
          mtu=>$conf{PPPOE_MTU},
          vlan_id_outer=>$conf{VLAN_TAG},
          physical_interface=>$thisPhysicalInterface,
          host_fine_stats_enabled=>"false",
          tcp_characteristics=>$TcpCharacteristicsDefault,
          service_state=>$ServiceState));
        }
        else {
          $Tg->Add(diversifEye::DirectVirtualHost->
          new(name=>$host_name,
          ip_assignment_type=>"PPPoE/IPv4CP",
          pppoe_settings=>$Ps,
          mac_address_assignment_mode=>$MacAssignmentMode,
          mac_address=>$pppoe_mac,
          mtu=>$conf{PPPOE_MTU},
          vlan_id_outer=>$conf{VLAN_TAG},
          physical_interface=>$thisPhysicalInterface,
          host_fine_stats_enabled=>"false",
          tcp_characteristics=>$TcpCharacteristicsDefault,
          service_state=>$ServiceState));
        }

        if ($conf{PPPOE_MAC_START} ne "") {
          $pppoe_mac++;
        }
        elsif (isMacObj($Ma{$pppoe_card_mac_addr})) {
          $Ma{$pppoe_card_mac_addr}++;
          $pppoe_mac = $Ma{$pppoe_card_mac_addr};
        }
      }
    }
  }
}


#
# Now create the background ping apps
#
if (($bPingEnabled == 1) && ($VERSION >= 8.5))
{
  printf(STDERR "%s\n", 'Generating Background Ping Applications ...');
  for $pdn (0..$PDNs_per_UE-1) {
    if ($useScaledEntities eq 1) {

      @UeGroups = ();
      $oddOrEvenOrNone = "all";
      $mtmoStr = "";
      push(@UeGroups, "0..".($conf{UEs}-1));

      if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
        @pppoeGroups = ();
        if (index($pppoeGroupList[$pdn], ",") != -1) {
          @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
        }
        else {
          push(@pppoeGroups, $pppoeGroupList[$pdn]);
        }

        @NewUeGroups = ();
        @PPPoEHostsForSplitGroups = {};
        foreach  $thisUeRange (@UeGroups) {
          $thisUeRange =~ s/-/\.\./g;
          if ($thisUeRange =~ m/\.\./) {
            ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
            if ($ueMaxVal eq "") { # for the case "x.."
              $ueMaxVal = $conf{UEs};
            }
          }
          else {
             $ueMinVal = $thisUeRange;
             $ueMaxVal = $thisUeRange;
          }

          # We need to align the ranges with the unerlying PPPoE Hosts
          @sortedPppoeGroups = sort(@pppoeGroups);
          foreach  $thisPPPoERange (@sortedPppoeGroups) {
            if ($thisPPPoERange =~ m/\.\./) {
              ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
              if ($pppMaxVal eq "") { # for the case "x.."
                $pppMaxVal = $conf{UEs};
              }
            }
            else {
               $pppMinVal = $thisPPPoERange;
               $pppMaxVal = $thisPPPoERange;
            }
            if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
              if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                if ($ueMinVal == $ueMaxVal) {
                  push(@NewUeGroups, $ueMaxVal);
                  $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                  $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                }
                else {
                  push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                  $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                  $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                }
              }
              else {
                if ($ueMinVal == $pppMaxVal) {
                  push(@NewUeGroups, $pppMaxVal);
                  $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                  $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                }
                else {
                  push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                  $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                  $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                }
                $ueMinVal = $pppMaxVal + 1;
              }
            }
          }
        }
        @UeGroups = @NewUeGroups;
      }

      foreach  $thisUeRange (@UeGroups) {

        ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn, $mtmoStr);

        if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
          ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
          $thisPppoeStartPos = $startingAt - $pppMinVal;
          if (index($bPingTargetIp, ":") != -1) {
             $thisHost = diversifEye::PsScaled->new(scaled_entity=>"pppoe6_".$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
          }
          else {
             $thisHost = diversifEye::PsScaled->new(scaled_entity=>"pppoe_".$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
          }
        }
        else {
          if (index($bPingTargetIp, ":") != -1) {
             $thisHost = diversifEye::PsScaled->new(scaled_entity=>"pppoe6_".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
          }
          else {
             $thisHost = diversifEye::PsScaled->new(scaled_entity=>"pppoe_".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
          }
        }

        $Tg->NewTemplate();
        $Tg->Add(diversifEye::PingApp->new(scale_factor=>$scaleFactor,
          name=>diversifEye::PsAlnum->new(prefix_label=>"bgping_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>"bgping_".$overrideName),
          description=>"Background Ping",
          host=>$thisHost,
          is_normal_stats_enabled=>$NormalStatsEnabled,
          is_fine_stats_enabled=>$FineStatsEnabled,
          aggregate_group=>$thisAggregateGroupName,
          ping_ip_address=>$bPingTargetIp,
          delay_between_pings=>$bPingInterval,
          delay_between_pings_metric=>"ms",
          packet_size=>$bPingPayloadSize,
          service_state=>$ServiceState));
      }
    }
    else {
      for $ue (0..$conf{UEs}-1) {
        $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
        $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);
        $base_name = $ueStr."_".sprintf("%s", $pdn);


        if ($doStatisticGroups) {
          $thisAggregateGroupName = "bping_".$base_name;
        }
        else {
          $thisAggregateGroupName = "";
        }

        $isIPv6Host = 0;
        if ($PPPoEIPv6Enabled eq 1) {
          if (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange eq "")) {
            $isIPv6Host = 1;
          }
          elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange ne "")) {
            if ((isInRange($ue, $PPPoEIPv6UeRange) == 1) && (isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
              $isIPv6Host = 1;
            }
          }
          elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange eq "")) {
            if ((isInRange($ue, $PPPoEIPv6UeRange) == 1)) {
              $isIPv6Host = 1;
            }
          }
          elsif (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange ne "")) {
            if ((isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
              $isIPv6Host = 1;
            }
          }
        }

        if ( ($isIPv6Host eq 0) && (index($bPingTargetIp, ":") == -1) ) {
          $Tg->NewTemplate();
          $Tg->Add(diversifEye::PingApp->
              new(name=>"bgping_".$base_name,
              description=>"Background Ping",
              host=>$host_name,
              is_normal_stats_enabled=>$NormalStatsEnabled,
              is_fine_stats_enabled=>$FineStatsEnabled,
              aggregate_group=>$thisAggregateGroupName,
              ping_ip_address=>$bPingTargetIp,
              delay_between_pings=>$bPingInterval,
              delay_between_pings_metric=>"ms",
              packet_size=>$bPingPayloadSize,
              service_state=>$ServiceState));
        }
        elsif ( ($isIPv6Host eq 1) && (index($bPingTargetIp, ":") != -1) ) {
          $Tg->NewTemplate();
          $Tg->Add(diversifEye::PingApp->
              new(name=>"bgping_".$base_name,
              description=>"Background Ping",
              host=>$host_name,
              is_normal_stats_enabled=>$NormalStatsEnabled,
              is_fine_stats_enabled=>$FineStatsEnabled,
              aggregate_group=>$thisAggregateGroupName,
              ping_ip_address=>$bPingTargetIp,
              delay_between_pings=>$bPingInterval,
              delay_between_pings_metric=>"ms",
              packet_size=>$bPingPayloadSize,
              service_state=>$ServiceState));
        }
      }
    }
  }
}





#
# Now Create the Server Applications
#
printf(STDERR "%s\n", 'Generating Server Applications ...');
for $i (0..$#hconf) {

  $thisHostName = $hconf[$i]{HostName};

  if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'HTTPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::HttpServer->
    new (name=>$hconf[$i]{HostName}."_http",
    host=>$thisHostName,
    resource_list=>"Internal Server Resource List",
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));

    if (($VERSION >= 8) && ($HttpTlsSupportNeeded == 1)) { # Add HTTPS (TLS) Server also
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::HttpServer->
      new (name=>$hconf[$i]{HostName}."_https",
      host=>$thisHostName,
      transport_port=>"443",
      resource_list=>"Internal Server Resource List",
      enable_tls=>"true",
      tcp_characteristics=>$TcpCharacteristicsDefault,
      administrative_state=>$AsOther));
    }

  }
  if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'HTTPServer') {
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalHttpServer-> new(
    name=>$hconf[$i]{HostName}."_http",
    host=>$thisHostName,
    administrative_state=>$AsOther));

    if (($VERSION >= 8) && ($HttpTlsSupportNeeded == 1)) { # Add HTTPS (TLS) Server also
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalHttpServer-> new(
      name=>$hconf[$i]{HostName}."_https",
      transport_port=>"443",
      host=>$thisHostName,
      administrative_state=>$AsOther));
    }

  }
  if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'HTTPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisServerName = $hconf[$i]{HostName}."_http".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::HttpServer->
    new (name=>$thisServerName,
    host=>$thisHostName,
    resource_list=>"Internal Server Resource List",
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));

    if (($VERSION >= 8) && ($HttpTlsSupportNeeded == 1)) { # Add HTTPS (TLS) Server also

      $thisServerName = $hconf[$i]{HostName}."_https".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }

      $Tg->NewTemplate();
      $Tg->Add(diversifEye::HttpServer->
      new (name=>$thisServerName,
      host=>$thisHostName,
      transport_port=>"443",
      resource_list=>"Internal Server Resource List",
      enable_tls=>"true",
      tcp_characteristics=>$TcpCharacteristicsDefault,
      administrative_state=>$AsOther));
    }

  }
  if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'HTTPServer') {
    $thisServerName = $hconf[$i]{HostName}."_http".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalHttpServer-> new(
    name=>$thisServerName,
    host=>$thisHostName,
    administrative_state=>$AsOther));

    if (($VERSION >= 8) && ($HttpTlsSupportNeeded == 1)) { # Add HTTPS (TLS) Server also
      $thisServerName = $hconf[$i]{HostName}."_https".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalHttpServer-> new(
      name=>$thisServerName,
      transport_port=>"443",
      host=>$thisHostName,
      administrative_state=>$AsOther));
    }
  }
  if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'FTPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::FtpServer-> new(
    name=>$hconf[$i]{HostName}."_ftp",
    host=>$thisHostName,
    file_list=>"Internal Server Resource List",
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'FTPServer') {
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalFtpServer-> new(
    name=>$hconf[$i]{HostName}."_ftp",
    host=>$thisHostName,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'FTPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisServerName = $hconf[$i]{HostName}."_ftp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::FtpServer-> new(
    name=>$thisServerName,
    host=>$thisHostName,
    file_list=>"Internal Server Resource List",
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'FTPServer') {
    $thisServerName = $hconf[$i]{HostName}."_ftp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalFtpServer-> new(
    name=>$thisServerName,
    host=>$thisHostName,
    administrative_state=>$AsOther));
  }

  if ($hconf[$i]{Application} eq 'ExternalSIPServer') {
    if ($hconf[$i]{ServerPorts} eq "") {
      $hconf[$i]{ServerPorts} = $SIPTransportPort;
    }

    if (index($hconf[$i]{ServerPorts}, ",") != -1) {
      @sipPorts = split(",", $hconf[$i]{ServerPorts});
      foreach $portVal (@sipPorts) {
        if ($hconf[$i]{Type} eq 'v6_EServer') {
          $thisSipValName = $hconf[$i]{HostName}."_voip".$v6suffix;
        }
        else {
          $thisSipValName = $hconf[$i]{HostName}."_voip";
        }
        if ($portVal != $SIPTransportPort) {
          $thisSipValName = $thisSipValName."_".$portVal;
        }
        if ($hconf[$i]{Type} eq 'v6_EServer') {
          if ((grep /^$thisSipValName/,@IpV6ServerHostNames) == 0) {
            push(@IpV6ServerHostNames, $thisSipValName);
          }
        }
        $Tg->NewTemplate();
        $Tg->Add(diversifEye::ExternalVoipSipProxy->
        new(name=>$thisSipValName,
        host=>$thisHostName,
        sip_domain_name=>$hconf[$i]{SIPDomain},
        transport_port=>$portVal,
        administrative_state=>$AsOther));
      }
    }
    else {
        if ($hconf[$i]{Type} eq 'v6_EServer') {
          $thisSipValName = $hconf[$i]{HostName}."_voip".$v6suffix;
          if ((grep /^$thisSipValName/,@IpV6ServerHostNames) == 0) {
            push(@IpV6ServerHostNames, $thisSipValName);
          }
        }
        else {
          $thisSipValName = $hconf[$i]{HostName}."_voip";
        }
        if ($hconf[$i]{ServerPorts} != $SIPTransportPort) {
          $thisSipValName = $thisSipValName."_".$hconf[$i]{ServerPorts};
        }

        $Tg->NewTemplate();
        $Tg->Add(diversifEye::ExternalVoipSipProxy->
        new(name=>$thisSipValName,
        host=>$thisHostName,
        sip_domain_name=>$hconf[$i]{SIPDomain},
        transport_port=>$hconf[$i]{ServerPorts},
        administrative_state=>$AsOther));
    }
  }

  if ($hconf[$i]{Application} eq 'SIPServer') {

    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisRtpPort = $VoipPortProfileDefault;

    if ($hconf[$i]{ServerPorts} eq "") {
      $hconf[$i]{ServerPorts} = $SIPTransportPort;
    }

    if ($hconf[$i]{Type} eq 'v6_DVHS') {
      $thisSipValName = $hconf[$i]{HostName}."_voip".$v6suffix;
      if ((grep /^$thisSipValName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisSipValName);
      }
    }

    if (index($hconf[$i]{ServerPorts}, ",") != -1) {
      @sipPorts = split(",", $hconf[$i]{ServerPorts});
      foreach $portVal (@sipPorts) {

        if ($hconf[$i]{Type} eq 'v6_DVHS') {
          $thisSipValName = $hconf[$i]{HostName}."_voip".$v6suffix;
        }
        else {
          $thisSipValName = $hconf[$i]{HostName}."_voip";
        }

        if ($portVal != $SIPTransportPort) {
          $thisSipValName = $thisSipValName."_".$portVal;
        }

        $Tg->NewTemplate();
        if ($VERSION >= 8.2) {
          $Tg->Add(diversifEye::VoipUas->
          new(name=>$thisSipValName,
          host=>$thisHostName,
          rtp_ports=>$thisRtpPort,
          enable_send_100_trying=>'false',
          sip_user_name=>"Admin",
          sip_domain_name=>$hconf[$i]{SIPDomain},
          generate_rtcp_reports=>'false',
          transport_port=>$portVal,
          administrative_state=>$AsOther));
        }
        else {
          $Tg->Add(diversifEye::VoipUas->
          new(name=>$thisSipValName,
          host=>$thisHostName,
          rtp_ports=>$thisRtpPort,
          enable_send_100_trying=>'false',
          playback_resource_list=>"PlayBackFiles",
          sip_user_name=>"Admin",
          sip_domain_name=>$hconf[$i]{SIPDomain},
          generate_rtcp_reports=>'false',
          use_capture_timings=>'true',
          transport_port=>$portVal,
          administrative_state=>$AsOther));
        }
      }
    }
    else {
      if ($hconf[$i]{Type} eq 'v6_DVHS') {
        $thisSipValName = $hconf[$i]{HostName}."_voip".$v6suffix;
      }
      else {
        $thisSipValName = $hconf[$i]{HostName}."_voip";
      }

      $Tg->NewTemplate();
      if ($VERSION >= 8.2) {
        $Tg->Add(diversifEye::VoipUas->
        new(name=>$thisSipValName,
        host=>$thisHostName,
        rtp_ports=>$thisRtpPort,
        enable_send_100_trying=>'false',
        sip_user_name=>"Admin",
        sip_domain_name=>$hconf[$i]{SIPDomain},
        generate_rtcp_reports=>'false',
        transport_port=>$hconf[$i]{ServerPorts},
        administrative_state=>$AsOther));
      }
      else {
        $Tg->Add(diversifEye::VoipUas->
        new(name=>$thisSipValName,
        host=>$thisHostName,
        rtp_ports=>$thisRtpPort,
        enable_send_100_trying=>'false',
        playback_resource_list=>"PlayBackFiles",
        sip_user_name=>"Admin",
        sip_domain_name=>$hconf[$i]{SIPDomain},
        generate_rtcp_reports=>'false',
        use_capture_timings=>'true',
        transport_port=>$hconf[$i]{ServerPorts},
        administrative_state=>$AsOther));
      }
    }
  }

  if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'MLDServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }
    $Tg->Add(diversifEye::MldServer->
    new(name=>$hconf[$i]{HostName}."_mld",
    host=>$thisHostName,
    transport_port=>'10000',
    media_transport=>"RTP",
    multicast_group_list=>'v6_Channels',
    stream_content=>'Data',
    data_rate=>'1',
    administrative_state=>$AsOther));
  }

  if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'RTSPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisRtspPort = $RtspPortProfileDefault;

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::RtspServer->
    new(name=>$hconf[$i]{HostName}."_rtsp",
    host=>$thisHostName,
    tcp_characteristics=>$TcpCharacteristicsDefault,
    media_resource_list=>"Internal Server Resource List",
    media_ports=>$thisRtspPort,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'RTSPServer') {

    $thisTransportPort = $RtspTransportPortDefault;

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalRtspServer-> new(
    name=>$hconf[$i]{HostName}."_rtsp",
    host=>$thisHostName,
    transport_port=>$thisTransportPort,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'RTSPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisServerName = $hconf[$i]{HostName}."_rtsp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $thisRtspPort = $RtspPortProfileDefault;

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::RtspServer->
    new(name=>$thisServerName,
    host=>$thisHostName,
    tcp_characteristics=>$TcpCharacteristicsDefault,
    media_resource_list=>"Internal Server Resource List",
    media_ports=>$thisRtspPort,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'RTSPServer') {

    $thisTransportPort = $RtspTransportPortDefault;

    $thisServerName = $hconf[$i]{HostName}."_rtsp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalRtspServer-> new(
    name=>$thisServerName,
    host=>$thisHostName,
    transport_port=>$thisTransportPort,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'TWAMPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::TwampServer->
    new (name=>$hconf[$i]{HostName}."_twamp",
    host=>$thisHostName,
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'TWAMPServer') {
    $Tg->NewTemplate();
    $Tg->Add(diversifEye::ExternalTwampServer-> new(
    name=>$hconf[$i]{HostName}."_twamp",
    host=>$thisHostName,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'TWAMPServer') {
    if ($hconf[$i]{ServerIp} ne "") {
      $thisHostName = "Host_".$hconf[$i]{ServerIp};
      $thisHostName =~ s/:/-/g;
    }

    $thisServerName = $hconf[$i]{HostName}."_twampp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->NewTemplate();
    $Tg->Add(diversifEye::TwampServer->
    new (name=>$thisServerName,
    host=>$thisHostName,
    tcp_characteristics=>$TcpCharacteristicsDefault,
    administrative_state=>$AsOther));
  }
  if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'TWAMPServer') {
    $Tg->NewTemplate();

    $thisServerName = $hconf[$i]{HostName}."_twamp".$v6suffix;
    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
      push(@IpV6ServerHostNames, $thisServerName);
    }

    $Tg->Add(diversifEye::ExternalTwampServer-> new(
    name=>$thisServerName,
    host=>$thisHostName,
    administrative_state=>$AsOther));
  }

  if ($VERSION >= 10) {  # Only available on v10 and above
    if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'TeraFlowServer') {
      if ($hconf[$i]{ServerIp} ne "") {
        $thisHostName = "Host_".$hconf[$i]{ServerIp};
        $thisHostName =~ s/:/-/g;
      }
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::TeraFlowServer->
      new (name=>$hconf[$i]{HostName}."_tf",
      host=>$thisHostName,
      transport_port=>$hconf[$i]{TransportPort},
      protocol=>$hconf[$i]{Protocol},
      tcp_characteristics=>$TcpCharacteristicsDefault,
      administrative_state=>$AsOther));
    }
    if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'TeraFlowServer') {
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalTeraFlowServer-> new(
      name=>$hconf[$i]{HostName}."_tf",
      host=>$thisHostName,
      transport_port=>$hconf[$i]{TransportPort},
      administrative_state=>$AsOther));
    }
    if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'TeraFlowServer') {
      if ($hconf[$i]{ServerIp} ne "") {
        $thisHostName = "Host_".$hconf[$i]{ServerIp};
        $thisHostName =~ s/:/-/g;
      }

      $thisServerName = $hconf[$i]{HostName}."_tf".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }

      $Tg->NewTemplate();
      $Tg->Add(diversifEye::TeraFlowServer->
      new (name=>$thisServerName,
      host=>$thisHostName,
      transport_port=>$hconf[$i]{TransportPort},
      protocol=>$hconf[$i]{Protocol},
      tcp_characteristics=>$TcpCharacteristicsDefault,
      administrative_state=>$AsOther));
    }
    if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'TeraFlowServer') {
      $thisServerName = $hconf[$i]{HostName}."_tf".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalTeraFlowServer-> new(
      name=>$thisServerName,
      host=>$thisHostName,
      transport_port=>$hconf[$i]{TransportPort},
      administrative_state=>$AsOther));
    }
  }

  if ($VERSION >= 11) {  # Only available on v11 and above
     if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'MLDServer') {

       $thisServerName = $hconf[$i]{HostName}."_mld".$v6suffix;
       if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
         push(@IpV6ServerHostNames, $thisServerName);
       }

       if ($hconf[$i]{ServerIp} ne "") {
         $thisHostName = "Host_".$hconf[$i]{ServerIp};
         $thisHostName =~ s/:/-/g;
       }

       $thisMediaTransport = "RTP";
       if (uc($hconf[$i]{MediaType}) eq "MPEG2-TS/RTP") {
         $thisMediaTransport = "MPEG2-TS";  # Overrite with a default.
       }
       elsif (uc($hconf[$i]{MediaType}) eq "MPEG2-TS") {
         $thisMediaTransport = "MPEG2-TS";
       }

       $Tg->NewTemplate();
       $Tg->Add(diversifEye::MldServer->new (
       name=>$hconf[$i]{HostName}."_mld",
       host=>$thisHostName,
       media_transport=>$thisMediaTransport,
       multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_mld".$v6suffix,
       stream_content=>"Data",
       data_rate=>$hconf[$i]{DataRate},
       data_rate_metric=>"Mbits/s",
       payload_size=>$hconf[$i]{PayloadSize},
       administrative_state=>$AsOther));
    }

    if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'MLDServer') {

      $thisServerName = $hconf[$i]{HostName}."_mld".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }

      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalMldServer-> new(
      name=>$thisServerName,
      host=>$thisHostName,
      multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_mld",
      administrative_state=>$AsOther));
    }

    if ($hconf[$i]{Type} eq 'v4_DVHS' && $hconf[$i]{Application} eq 'IGMPServer') {
      if ($hconf[$i]{ServerIp} ne "") {
        $thisHostName = "Host_".$hconf[$i]{ServerIp};
        $thisHostName =~ s/:/-/g;
      }

      $thisMediaTransport = "RTP";
      if (uc($hconf[$i]{MediaType}) eq "MPEG2-TS/RTP") {
        $thisMediaTransport = "MPEG2-TS";  # Overrite with a default.
      }
      elsif (uc($hconf[$i]{MediaType}) eq "MPEG2-TS") {
        $thisMediaTransport = "MPEG2-TS";
      }

      $Tg->NewTemplate();
      $Tg->Add(diversifEye::IgmpServer->new (
      name=>$hconf[$i]{HostName}."_igmp",
      host=>$thisHostName,
      media_transport=>$thisMediaTransport,
      multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_igmp",
      data_rate=>$hconf[$i]{DataRate},
      data_rate_metric=>"Mbits/s",
      payload_size=>$hconf[$i]{PayloadSize},
      administrative_state=>$AsOther));
    }

    if ($hconf[$i]{Type} eq 'v4_EServer' && $hconf[$i]{Application} eq 'IGMPServer') {
      $thisServerName = $hconf[$i]{HostName}."_igmp";
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalIgmpServer-> new(
      name=>$thisServerName,
      host=>$thisHostName,
      multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_igmp",
      administrative_state=>$AsOther));
    }

    if ($hconf[$i]{Type} eq 'v6_DVHS' && $hconf[$i]{Application} eq 'IGMPServer') {

      $thisServerName = $hconf[$i]{HostName}."_igmp".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }

      if ($hconf[$i]{ServerIp} ne "") {
        $thisHostName = "Host_".$hconf[$i]{ServerIp};
        $thisHostName =~ s/:/-/g;
      }

      $thisMediaTransport = "RTP";
      if (uc($hconf[$i]{MediaType}) eq "MPEG2-TS/RTP") {
        $thisMediaTransport = "MPEG2-TS";  # Overrite with a default.
      }
      elsif (uc($hconf[$i]{MediaType}) eq "MPEG2-TS") {
        $thisMediaTransport = "MPEG2-TS";
      }

      $Tg->NewTemplate();
      $Tg->Add(diversifEye::IgmpServer->new (
      name=>$hconf[$i]{HostName}."_igmp",
      host=>$thisHostName,
      media_transport=>$thisMediaTransport,
      multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_igmp".$v6suffix,
      data_rate=>$hconf[$i]{DataRate},
      data_rate_metric=>"Mbits/s",
      payload_size=>$hconf[$i]{PayloadSize},
      administrative_state=>$AsOther));
    }

    if ($hconf[$i]{Type} eq 'v6_EServer' && $hconf[$i]{Application} eq 'IGMPServer') {
      $thisServerName = $hconf[$i]{HostName}."_igmp".$v6suffix;
      if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
        push(@IpV6ServerHostNames, $thisServerName);
      }
      $Tg->NewTemplate();
      $Tg->Add(diversifEye::ExternalIgmpServer-> new(
      name=>$thisServerName,
      host=>$thisHostName,
      multicast_group_list=>"Iggl".$hconf[$i]{HostName}."_igmp".$v6suffix,
      administrative_state=>$AsOther));
    }



  }
}

# Create HTTP severs on PPPoE hosts

printf(STDERR "%s\n", 'Generating HTTP Server Applications on PPPoE Hosts ...');
@ShttpAliasNames = ();

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $profileName = "Default";
    $suffix = "";
  }
  else {
    $profileName = "Profile_$profileId";
    $suffix = "_P$profileId";
  }
  $loadProfilesKey = $ClientProfilesKey->{$profileName};

  if ((defined $loadProfilesKey->{'SHTTP'}) && ($HttpEnabled eq 1)) {  # Don't create if there are no http clients
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'SHTTP'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'SHTTP'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
        $AliasEntryName = $Alias.$rangeStr."_".$profileName."_SHTTP";
      }
      else {
        $Alias = $defaultShttpAlias;
        $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
      }

      $TcpCharacteristicsName = $TcpCharacteristicsDefault;
      if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
        if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
              (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
          if ($Alias eq $defaultShttpAlias) {
            $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
          }
          else {
            $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharShttpId;
          }
        }
      }

      $thisUseTLS = "false";
      $thisPort = "80";
      if (defined $thisKey->[$i]->{'Use_TLS'}) {
        if ($thisKey->[$i]->{'Use_TLS'} eq "true") {
          $thisUseTLS = "true";
          $thisPort = "443";
        }
      }

      if (defined $thisKey->[$i]->{'Description'}) {
        $thisShttpDescription = $thisKey->[$i]->{'Description'};
      }
      else {
        if (($thisUseTLS eq "true") && ($VERSION >= 8)) {
          $thisShttpDescription = $defaultShttpsDescription;  # The default description
        }
        else {
          $thisShttpDescription = $defaultShttpDescription;  # The default description
        }
      }

      for $pdn (0..$PDNs_per_UE-1) {

        if ($Alias eq $defaultShttpAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_SHTTP_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@ShttpAliasNames) == 0) {
          push(@ShttpAliasNames, $AliasEntryName);

          if ($useScaledEntities eq 1) {

            $createPdnEntry = 0;
            if ($PdnRange eq "") {
              $createPdnEntry = 1;
            }
            elsif ($PdnRange ne "") {
              if ((isInRange($pdn, $PdnRange) == 1)) {
                $createPdnEntry = 1;
              }
            }

            if ($createPdnEntry eq 1) {
              if ($UeRange eq "") {
                $UeRange = "0..".($conf{UEs}-1);
              }

              @UeGroups = ();
              if (index($UeRange, ",") != -1) {
                @UeGroups = split(",", $UeRange);
              }
              else {
                push(@UeGroups, $UeRange);
              }

              if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                @pppoeGroups = ();
                if (index($pppoeGroupList[$pdn], ",") != -1) {
                  @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                }
                else {
                  push(@pppoeGroups, $pppoeGroupList[$pdn]);
                }

                @NewUeGroups = ();
                @PPPoEHostsForSplitGroups = {};
                foreach  $thisUeRange (@UeGroups) {
                  $thisUeRange =~ s/-/\.\./g;
                  if ($thisUeRange =~ m/\.\./) {
                    ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                    if ($ueMaxVal eq "") { # for the case "x.."
                      $ueMaxVal = $conf{UEs};
                    }
                  }
                  else {
                     $ueMinVal = $thisUeRange;
                     $ueMaxVal = $thisUeRange;
                  }

                  # We need to align the ranges with the unerlying PPPoE Hosts
                  @sortedPppoeGroups = sort(@pppoeGroups);
                  foreach  $thisPPPoERange (@sortedPppoeGroups) {
                    if ($thisPPPoERange =~ m/\.\./) {
                      ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                      if ($pppMaxVal eq "") { # for the case "x.."
                        $pppMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $pppMinVal = $thisPPPoERange;
                       $pppMaxVal = $thisPPPoERange;
                    }
                    if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                      if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                        if ($ueMinVal == $ueMaxVal) {
                          push(@NewUeGroups, $ueMaxVal);
                          $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                          $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                        }
                        else {
                          push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                          $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                          $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                        }
                      }
                      else {
                        if ($ueMinVal == $pppMaxVal) {
                          push(@NewUeGroups, $pppMaxVal);
                          $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                          $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                        }
                        else {
                          push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                          $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                          $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                        }
                        $ueMinVal = $pppMaxVal + 1;
                      }
                    }
                  }
                }
                @UeGroups = @NewUeGroups;
              }

              $oddOrEvenOrNone = "all";
              if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                  $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                }
              }

              foreach  my $thisUeRange (@UeGroups) {

                $Tg->NewTemplate();
                $mtmoStr = "";
                if ($Alias ne $defaultHttpAlias) {
                  $mtmoStr = "";
                }
                ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn, $mtmoStr);
                $prefixLabel = $Alias."_";
                $suffixLabel = "_".$pdn;

                $pppoeStr = "pppoe_";
                if (defined $thisKey->[$i]->{'Ip_Version'}) {
                  if ($thisKey->[$i]->{'Ip_Version'} eq "6") {
                    $pppoeStr = "pppoe6_";
                    $thisServerName = $Alias."_".$overrideName;
                    if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
                      push(@IpV6ServerHostNames, $thisServerName);
                    }
                  }
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                  $thisPppoeStartPos = $startingAt - $pppMinVal;
                  $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                }
                else {
                  $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                }

                $Tg->Add(diversifEye::HttpServer->new(scale_factor=>$scaleFactor,
                name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                description=>$thisShttpDescription,
                transport_port=>$thisPort,
                host=>$thisHost,
                resource_list=>"Internal Server Resource List",
                enable_tls=>$thisUseTLS,
                tcp_characteristics=>$TcpCharacteristicsName,
                administrative_state=>$AsOther));
              }
            }
          }
          else {

            for $ue (0..$conf{UEs}-1) {

              $createEntry = 0;
              if (($UeRange eq "") && ($PdnRange eq "")) {
                $createEntry = 1;
              }
              elsif (($UeRange ne "") && ($PdnRange ne "")) {
                if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                  $createEntry = 1;
                }
              }
              elsif (($UeRange ne "") && ($PdnRange eq "")) {
                if ((isInRange($ue, $UeRange) == 1)) {
                  $createEntry = 1;
                }
              }
              elsif (($UeRange eq "") && ($PdnRange ne "")) {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createEntry = 1;
                }
              }

              if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                  if ($ue % 2) {  # If the UE is odd then clear the create flag.
                    $createEntry = 0;
                  }
                }
                elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                  if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                    $createEntry = 0;
                  }
                }
              }

              if ($createEntry)  {
                $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                 if ($profileId == -1) {
                  $base_name = $ueStr."_".sprintf("%s", $pdn);
                }
                else {
                  $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                }
                $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                if (($thisUseTLS eq "true") && ($VERSION >= 8)) {
                  $thisShttpName = $Alias."_".$base_name."_https";
                }
                else {
                  $thisShttpName = $Alias."_".$base_name; # ."_http";
                }

                $Tg->NewTemplate();
                $Tg->Add(diversifEye::HttpServer->
                new (name=>$thisShttpName,
                description=>$thisShttpDescription,
                transport_port=>$thisPort,
                host=>$host_name,
                resource_list=>"Internal Server Resource List",
                enable_tls=>$thisUseTLS,
                tcp_characteristics=>$TcpCharacteristicsName,
                administrative_state=>$AsOther));
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }
}



# Create Teraflow severs on PPPoE hosts
printf(STDERR "%s\n", 'Generating Teraflow Server Applications on PPPoE Hosts ...');
@TeraFlowAliasNames = ();

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $profileName = "Default";
    $suffix = "";
  }
  else {
    $profileName = "Profile_$profileId";
    $suffix = "_P$profileId";
  }
  $loadProfilesKey = $ClientProfilesKey->{$profileName};

  if ((defined $loadProfilesKey->{'TeraFlow'}) && ($TeraFlowEnabled eq 1) && ($VERSION >= 10)) {
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'}];
    }

    foreach (@{$thisKey}) {
      if (defined $thisKey->[$i]->{'Server_on_PPPoE'}) {
        if (lc($thisKey->[$i]->{'Server_on_PPPoE'}) eq "true") {

          $UeRange = "";
          $PdnRange = "";
          if (defined $thisKey->[$i]->{'UE'}) {
            $UeRange = $thisKey->[$i]->{'UE'};
          }

          if (defined $thisKey->[$i]->{'PDN'}) {
            $PdnRange = $thisKey->[$i]->{'PDN'};
          }
          $rangeStr = cleanRange($UeRange, $PdnRange);

          if (defined $thisKey->[$i]->{'Alias'}) {
            $Alias = cleanAlias($thisKey->[$i]->{'Alias'})."_STF";
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;
          }
          else {
            $Alias = $defaultTeraFlowServerAlias;
            $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
          }

          $TcpCharacteristicsName = $TcpCharacteristicsDefault;
          if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
            if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
              if ($Alias eq $defaultShttpAlias) {
                $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
              }
              else {
                $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharTeraFlowId;
              }
            }
          }

          if (defined $thisKey->[$i]->{'Description'}) {
            $thisStfDescription = $thisKey->[$i]->{'Description'};
          }
          else {
            $thisStfDescription = $defaultTeraFlowDescription;  # The default description
          }


          $thisProtocol = "UDP";
          if (defined $thisKey->[$i]->{'TeraFlow_Transport_Type'}) {
            if (lc($thisKey->[$i]->{'TeraFlow_Transport_Type'}) eq "tcp") {
              $thisProtocol = "TCP";
            }
          }

          $thisTransportPort = "5001";
          if (defined $thisKey->[$i]->{'TeraFlow_Transport_Port'}) {
            if (($thisKey->[$i]->{'TeraFlow_Transport_Port'} ne "") && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} >= 1) && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} <= 65535)) {
              $thisTransportPort = $thisKey->[$i]->{'TeraFlow_Transport_Port'};
            }
          }

          for $pdn (0..$PDNs_per_UE-1) {

            if ($Alias eq $defaultTeraFlowAlias) {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
            }
            else {
              $AliasEntryName = $Alias.$rangeStr."_".$profileName."_STF_PDN".$pdn;
            }

            # Check the Alias has not been used if it has ignore configuration
            if ((grep /^$AliasEntryName/,@TeraFlowAliasNames) == 0) {
              push(@TeraFlowAliasNames, $AliasEntryName);

              if ($useScaledEntities eq 1) {

                $createPdnEntry = 0;
                if ($PdnRange eq "") {
                  $createPdnEntry = 1;
                }
                elsif ($PdnRange ne "") {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createPdnEntry = 1;
                  }
                }

                if ($createPdnEntry eq 1) {
                  if ($UeRange eq "") {
                    $UeRange = "0..".($conf{UEs}-1);
                  }

                  @UeGroups = ();
                  if (index($UeRange, ",") != -1) {
                    @UeGroups = split(",", $UeRange);
                  }
                  else {
                    push(@UeGroups, $UeRange);
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    @pppoeGroups = ();
                    if (index($pppoeGroupList[$pdn], ",") != -1) {
                      @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                    }
                    else {
                      push(@pppoeGroups, $pppoeGroupList[$pdn]);
                    }

                    @NewUeGroups = ();
                    @PPPoEHostsForSplitGroups = {};
                    foreach  $thisUeRange (@UeGroups) {
                      $thisUeRange =~ s/-/\.\./g;
                      if ($thisUeRange =~ m/\.\./) {
                        ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                        if ($ueMaxVal eq "") { # for the case "x.."
                          $ueMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $ueMinVal = $thisUeRange;
                         $ueMaxVal = $thisUeRange;
                      }

                      # We need to align the ranges with the unerlying PPPoE Hosts
                      @sortedPppoeGroups = sort(@pppoeGroups);
                      foreach  $thisPPPoERange (@sortedPppoeGroups) {
                        if ($thisPPPoERange =~ m/\.\./) {
                          ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                          if ($pppMaxVal eq "") { # for the case "x.."
                            $pppMaxVal = $conf{UEs};
                          }
                        }
                        else {
                           $pppMinVal = $thisPPPoERange;
                           $pppMaxVal = $thisPPPoERange;
                        }
                        if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                          if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                            if ($ueMinVal == $ueMaxVal) {
                              push(@NewUeGroups, $ueMaxVal);
                              $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                              $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                            }
                            else {
                              push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                              $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                              $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                            }
                          }
                          else {
                            if ($ueMinVal == $pppMaxVal) {
                              push(@NewUeGroups, $pppMaxVal);
                              $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                              $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                            }
                            else {
                              push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                              $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                              $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                            }
                            $ueMinVal = $pppMaxVal + 1;
                          }
                        }
                      }
                    }
                    @UeGroups = @NewUeGroups;
                  }

                  $oddOrEvenOrNone = "all";
                  if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                    if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                      $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                    }
                  }

                  foreach  $thisUeRange (@UeGroups) {

                    $Tg->NewTemplate();
                    ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn, "");
                    $prefixLabel = $Alias."_";
                    $suffixLabel = "_".$pdn;

                    $pppoeStr = "pppoe_";
                    if (defined $thisKey->[$i]->{'Ip_Version'}) {
                      if ($thisKey->[$i]->{'Ip_Version'} eq "6") {
                        $pppoeStr = "pppoe6_";
                        $thisServerName = $Alias."_".$overrideName;
                        if ((grep /^$thisServerName/,@IpV6ServerHostNames) == 0) {
                          push(@IpV6ServerHostNames, $thisServerName);
                        }
                      }
                    }


                    if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                      ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                      $thisPppoeStartPos = $startingAt - $pppMinVal;
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize))
                    }
                    else {
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize))
                    }

                    $Tg->Add(diversifEye::TeraFlowServer->new (scale_factor=>$scaleFactor,
                      name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                      description=>$thisStfDescription,
                      host=>$thisHost,
                      transport_port=>$thisTransportPort,
                      protocol=>$thisProtocol,
                      tcp_characteristics=>$TcpCharacteristicsDefault,
                      administrative_state=>$AsOther));
                  }
                }
              }
              else {

                for $ue (0..$conf{UEs}-1) {

                  $createEntry = 0;
                  if (($UeRange eq "") && ($PdnRange eq "")) {
                    $createEntry = 1;
                  }
                  elsif (($UeRange ne "") && ($PdnRange ne "")) {
                    if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange ne "") && ($PdnRange eq "")) {
                    if ((isInRange($ue, $UeRange) == 1)) {
                      $createEntry = 1;
                    }
                  }
                  elsif (($UeRange eq "") && ($PdnRange ne "")) {
                    if ((isInRange($pdn, $PdnRange) == 1)) {
                      $createEntry = 1;
                    }
                  }

                  if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                    if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                      if ($ue % 2) {  # If the UE is odd then clear the create flag.
                        $createEntry = 0;
                      }
                    }
                    elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                      if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                        $createEntry = 0;
                      }
                    }
                  }

                  if ($createEntry)  {
                    $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                     if ($profileId == -1) {
                      $base_name = $ueStr."_".sprintf("%s", $pdn);
                    }
                    else {
                      $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                    }
                    $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                    $thisStfName = $Alias."_".$base_name; # ."_http";

                    $Tg->NewTemplate();

                    $Tg->Add(diversifEye::TeraFlowServer->new (name=>$thisStfName,
                      description=>$thisStfDescription,
                      host=>$host_name,
                      transport_port=>$thisTransportPort,
                      protocol=>$thisProtocol,
                      tcp_characteristics=>$TcpCharacteristicsDefault,
                      administrative_state=>$AsOther));
                  }
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }
}





#
# Now Create the per-UE, per load profile, per-PDN client applications
#
$LastFtpGetAliasName = "";
$LastFtpPutAliasName = "";
$LastHttpAliasName = "";
$LastRtspAliasName = "";
#$LastVoipAliasName = "";
#$LastTwampAliasName = "";
#$LastTeraFlowAliasName = "";

@FtpGetAliasNames = ();
@FtpPutAliasNames = ();
@HttpAliasNames = ();
@VoipAliasNames = ();
@RtspAliasNames = ();
@TwampAliasNames = ();
@PingAliasNames = ();
#@TeraFlowAliasNames = ();
@VoIPApps = ();

printf(STDERR "%s\n", 'Generating Client Applications ...');

for ($profileId = -1; $profileId <= 9; $profileId++) {
  if ($profileId == -1) {
    $profileName = "Default";
    $suffix = "";
  }
  else {
    $profileName = "Profile_$profileId";
    $suffix = "_P$profileId";
  }
  $loadProfilesKey = $ClientProfilesKey->{$profileName};

  #
  #   FTP Get Client
  #
  if ((defined $loadProfilesKey->{'FTP_Get'}) && ($FtpGetEnabled eq 1)) {
    printf(STDERR "%s\n", 'Generating FTP Get Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Get'}];
    }

    foreach (@{$thisKey}) {

      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultFtpGetAlias;
      }

      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultFtpGetAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharFtpGetId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisFtpGetDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisFtpGetDescription = $defaultFtpGetDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisFtpGetServer = $thisKey->[$i]->{'Server_Host_Name'}."_ftp";
        }

        if (defined $thisKey->[$i]->{'Path'}) {
          if ($thisKey->[$i]->{'Path'} ne "") {
              $thisFtpGetPath = $thisKey->[$i]->{'Path'};
          }
        }
        else {
          $thisFtpGetPath = $FtpGetPath;
        }

        $thisFtpGetMode = "Passive";
        if (defined $thisKey->[$i]->{'FTP_Mode'}) {
          if ($thisKey->[$i]->{'FTP_Mode'} eq "Active") {
            $thisFtpGetMode = "Active";
          }
        }

        if (defined $thisKey->[$i]->{'Username'} && defined $thisKey->[$i]->{'Password'}) {
          $thisFtpGetIsAnonymous = 'false';
          $thisFtpGetUsername = $thisKey->[$i]->{'Username'};
          $thisFtpGetPassword = $thisKey->[$i]->{'Password'};
        }
        else {
          $thisFtpGetIsAnonymous = 'true';
          $thisFtpGetUsername = '';
          $thisFtpGetPassword = '';
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Commands'}) {
          if (($thisKey->[$i]->{'Delay_Between_Commands'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Commands'} <= 3600000)) {
            $thisFtpGetDelayBetweenCommands = $thisKey->[$i]->{'Delay_Between_Commands'};
          }
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Sessions'}) {
          if (($thisKey->[$i]->{'Delay_Between_Sessions'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Sessions'} <= 3600000)) {
            $thisFtpGetDelayBetweenSessions = $thisKey->[$i]->{'Delay_Between_Sessions'};
          }
        }

        if (defined $thisKey->[$i]->{'File_Size'}) {
          $thisFtpGetFileSize = $thisKey->[$i]->{'File_Size'};
        }
        else {
          $thisFtpGetFileSize = $FtpFileSize;
        }

        for $pdn (0..$PDNs_per_UE-1) {

          if ($Alias eq $defaultFtpGetAlias) {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
          }
          else {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Get_PDN".$pdn;
          }

          $listRangeStr = $rangeStr;
          $nameLen = length($Alias.$rangeStr.$FtpGetCmdListId.$suffix);
          if ($nameLen > 32) {
             $rangeLen = 32 - length($Alias.$FtpGetCmdListId.$suffix);
             if ($rangeLen > 0) {
                $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
             }
             else {
                $listRangeStr = "";
             }
          }

          $command_list = $Alias.$listRangeStr.$FtpGetCmdListId.$suffix;

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@FtpGetAliasNames) == 0) {
            push(@FtpGetAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach  $thisUeRange (@UeGroups) {

                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisTempFtpGetUsername = $thisFtpGetUsername;
                  $thisTempFtpGetPassword = $thisFtpGetPassword;
                  if ($thisFtpGetIsAnonymous eq 'false') {
                    if (index($thisTempFtpGetUsername, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempFtpGetUsername, 2);
                      $thisTempFtpGetUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftpuser_".$overrideName);
                    }
                    if (index($thisTempFtpGetPassword, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempFtpGetPassword, 2);
                      $thisTempFtpGetPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftppass_".$overrideName);
                    }
                  }

                  $prefixLabel = $Alias."_";
                  $suffixLabel = "_".$pdn;

                  if ((grep /^$thisFtpGetServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->Add(diversifEye::FtpClient->new (scale_factor=>$scaleFactor,
                  name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                  description=>$thisFtpGetDescription,
                  host=>$thisHost,
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  aggregate_group=>$thisAggregateGroupName,
                  tcp_characteristics=>$TcpCharacteristicsName,
                  server=>$thisFtpGetServer,
                  ftp_mode=>$thisFtpGetMode,
                  command_list=>$command_list,
                  delay_between_commands=>$thisFtpGetDelayBetweenCommands,
                  delay_between_commands_metric=>'ms',
                  delay_between_sessions=>$thisFtpGetDelayBetweenSessions,
                  delay_between_sessions_metric=>'ms',
                  is_anonymous_enabled=>$thisFtpGetIsAnonymous,
                  username=>$thisTempFtpGetUsername,
                  password=>$thisTempFtpGetPassword,
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther));
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {

                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ($LastFtpGetAliasName ne $AliasEntryName) {
                    $LastFtpGetAliasName = $AliasEntryName;
                    $Tg->NewTemplate();
                  }

                  $thisTempFtpGetUsername = $thisFtpGetUsername;
                  $thisTempFtpGetPassword = $thisFtpGetPassword;
                  if ($thisFtpGetIsAnonymous eq 'false') {
                    $thisTempFtpGetUsername =~ s/%UE_ID%/$ueStr/g;
                    $thisTempFtpGetPassword =~ s/%UE_ID%/$ueStr/g;
                  }

                  $Tg->Add(diversifEye::FtpClient->
                  new (name=>$Alias."_".$base_name,
                  description=>$thisFtpGetDescription,
                  host=>$host_name,
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  aggregate_group=>$thisAggregateGroupName,
                  tcp_characteristics=>$TcpCharacteristicsName,
                  server=>$thisFtpGetServer,
                  ftp_mode=>$thisFtpGetMode,
                  command_list=>$command_list,
                  delay_between_commands=>$thisFtpGetDelayBetweenCommands,
                  delay_between_commands_metric=>'ms',
                  delay_between_sessions=>$thisFtpGetDelayBetweenSessions,
                  delay_between_sessions_metric=>'ms',
                  is_anonymous_enabled=>$thisFtpGetIsAnonymous,
                  username=>$thisTempFtpGetUsername,
                  password=>$thisTempFtpGetPassword,
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther));
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }




  #
  #   FTP Put Client
  #
  if ((defined $loadProfilesKey->{'FTP_Put'}) && ($FtpPutEnabled eq 1)) {
    printf(STDERR "%s\n", 'Generating FTP Put Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'FTP_Put'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultFtpPutAlias;
      }

      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultFtpPutAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharFtpPutId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisFtpPutDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisFtpPutDescription = $defaultFtpPutDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisFtpPutServer = $thisKey->[$i]->{'Server_Host_Name'}."_ftp";
        }

        if (defined $thisKey->[$i]->{'Path'}) {
          if ($thisKey->[$i]->{'Path'} ne "") {
              $thisFtpPutPath = $thisKey->[$i]->{'Path'};
          }
        }
        else {
          $thisFtpPutPath = $FtpPutPath;
        }

        $thisFtpPutMode = "Passive";
        if (defined $thisKey->[$i]->{'FTP_Mode'}) {
          if ($thisKey->[$i]->{'FTP_Mode'} eq "Active") {
            $thisFtpPutMode = "Active";
          }
        }

        if (defined $thisKey->[$i]->{'Username'} && defined $thisKey->[$i]->{'Password'}) {
          $thisFtpPutIsAnonymous = 'false';
          $thisFtpPutUsername = $thisKey->[$i]->{'Username'};
          $thisFtpPutPassword = $thisKey->[$i]->{'Password'};
        }
        else {
          $thisFtpPutIsAnonymous = 'true';
          $thisFtpPutUsername = '';
          $thisFtpPutPassword = '';
        }

        $thisFtpPutPathShared = $FtpPutPathShared;
        $thisFtpPutPathIsShared = 0;
        if (defined $thisKey->[$i]->{'Ftp_Put_Path_Shared'}) {
          if ($thisKey->[$i]->{'Ftp_Put_Path_Shared'} ne "") {
            $thisFtpPutPathShared = $thisKey->[$i]->{'Ftp_Put_Path_Shared'};
            $thisFtpPutPathIsShared = 1;
          }
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Commands'}) {
          if (($thisKey->[$i]->{'Delay_Between_Commands'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Commands'} <= 3600000)) {
            $thisFtpPutDelayBetweenCommands = $thisKey->[$i]->{'Delay_Between_Commands'};
          }
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Sessions'}) {
          if (($thisKey->[$i]->{'Delay_Between_Sessions'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Sessions'} <= 3600000)) {
            $thisFtpPutDelayBetweenSessions = $thisKey->[$i]->{'Delay_Between_Sessions'};
          }
        }

        for $pdn (0..$PDNs_per_UE-1) {
          if ($Alias eq $defaultFtpPutAlias) {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
          }
          else {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_FTP_Put_PDN".$pdn;
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@FtpPutAliasNames) == 0) {
            push(@FtpPutAliasNames, $AliasEntryName);

            if ($doStatisticGroups) {
              $thisAggregateGroupName = $Alias."_".$base_name;
            }
            else {
              $thisAggregateGroupName = "";
            }

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }


                if ($thisFtpPutPathIsShared) {
                  $listRangeStr = $rangeStr;
                  $nameLen = length($Alias.$rangeStr.$FtpPutCmdListId.$suffix);
                  if ($nameLen > 32) {
                     $rangeLen = 32 - length($Alias.$FtpPutCmdListId.$suffix);
                     if ($rangeLen > 0) {
                        $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                     }
                     else {
                        $listRangeStr = "";
                     }
                  }
                  $command_list = $Alias.$listRangeStr.$FtpPutCmdListId.$suffix;
                }
                else {
                  $command_list = $Alias.$FtpPutCmdListId."_".$ue."_".$pdn.$suffix;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {

                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisTempFtpPutUsername = $thisFtpPutUsername;
                  $thisTempFtpPutPassword = $thisFtpPutPassword;
                  if ($thisFtpPutIsAnonymous eq 'false') {
                    if (index($thisTempFtpPutUsername, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempFtpPutUsername, 2);
                      $thisTempFtpPutUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftp_put_user_".$overrideName);
                    }
                    if (index($thisTempFtpPutPassword, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempFtpPutPassword, 2);
                      $thisTempFtpPutPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftp_put_pass_".$overrideName);
                    }
                  }

                  $prefixLabel = $Alias."_";
                  $suffixLabel = "_".$pdn;

                  if ((grep /^$thisFtpPutServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->Add(diversifEye::FtpClient->new(scale_factor=>$scaleFactor,
                  name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                  description=>$thisFtpPutDescription,
                  host=>$thisHost,
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  aggregate_group=>$thisAggregateGroupName,
                  tcp_characteristics=>$TcpCharacteristicsName,
                  server=>$thisFtpPutServer,
                  ftp_mode=>$thisFtpPutMode,
                  command_list=>$command_list,
                  delay_between_commands=>$thisFtpPutDelayBetweenCommands,
                  delay_between_commands_metric=>'ms',
                  delay_between_sessions=>$thisFtpPutDelayBetweenSessions,
                  delay_between_sessions_metric=>'ms',
                  is_anonymous_enabled=>$thisFtpPutIsAnonymous,
                  username=>$thisTempFtpPutUsername,
                  password=>$thisTempFtpPutPassword,
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther));
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {
                if ($thisFtpPutPathIsShared) {
                  $listRangeStr = $rangeStr;
                  $nameLen = length($Alias.$rangeStr.$FtpPutCmdListId.$suffix);
                  if ($nameLen > 32) {
                     $rangeLen = 32 - length($Alias.$FtpPutCmdListId.$suffix);
                     if ($rangeLen > 0) {
                        $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                     }
                     else {
                        $listRangeStr = "";
                     }
                  }
                  $command_list = $Alias.$listRangeStr.$FtpPutCmdListId.$suffix;
                }
                else {
                  $command_list = $Alias.$FtpPutCmdListId."_".$ue."_".$pdn.$suffix;
                }

                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ($LastFtpPutAliasName ne $AliasEntryName) {
                    $LastFtpPutAliasName = $AliasEntryName;
                    $Tg->NewTemplate();
                  }

                  $thisTempFtpPutUsername = $thisFtpPutUsername;
                  $thisTempFtpPutPassword = $thisFtpPutPassword;
                  if ($thisFtpPutIsAnonymous eq 'false') {
                    $thisTempFtpPutUsername =~ s/%UE_ID%/$ueStr/g;
                    $thisTempFtpPutPassword =~ s/%UE_ID%/$ueStr/g;
                  }

                  $Tg->Add(diversifEye::FtpClient->
                  new (name=>$Alias."_".$base_name,
                  description=>$thisFtpPutDescription,
                  host=>$host_name,
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  aggregate_group=>$thisAggregateGroupName,
                  tcp_characteristics=>$TcpCharacteristicsName,
                  server=>$thisFtpPutServer,
                  ftp_mode=>$thisFtpPutMode,
                  command_list=>$command_list,
                  delay_between_commands=>$thisFtpPutDelayBetweenCommands,
                  delay_between_commands_metric=>'ms',
                  delay_between_sessions=>$thisFtpPutDelayBetweenSessions,
                  delay_between_sessions_metric=>'ms',
                  is_anonymous_enabled=>$thisFtpPutIsAnonymous,
                  username=>$thisTempFtpPutUsername,
                  password=>$thisTempFtpPutPassword,
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther));
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }




  #
  #   HTTP Client
  #
  if ((defined $loadProfilesKey->{'HTTP'}) && ($HttpEnabled eq 1)) {
    printf(STDERR "%s\n", 'Generating HTTP Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'HTTP'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
        $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP";
      }
      else {
        $Alias = $defaultHttpAlias;
        $AliasEntryName = $Alias.$rangeStr."_".$profileName;  # The default name
      }

      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultHttpAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharHttpId;
            }
          }
        }

        $thisHttpUsername = "";
        if (defined $thisKey->[$i]->{'Username'}) {
          $thisHttpUsername = $thisKey->[$i]->{'Username'};
        }

        $thisHttpPassword = "";
        if (defined $thisKey->[$i]->{'Password'}) {
          $thisHttpPassword = $thisKey->[$i]->{'Password'};
        }

        $thisUseTLS = "false";
        if (defined $thisKey->[$i]->{'Use_TLS'}) {
          if ($thisKey->[$i]->{'Use_TLS'} eq "true") {
            $thisUseTLS = "true";
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisHttpDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          if (($thisUseTLS eq "true") && ($VERSION >= 8)) {
            $thisHttpDescription = $defaultHttpsDescription;  # The default description
          }
          else {
            $thisHttpDescription = $defaultHttpDescription;  # The default description
          }
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Requests'}) {
          if (($thisKey->[$i]->{'Delay_Between_Requests'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Requests'} <= 600000)) {
            $thisHttpDelayBetweenCommands = $thisKey->[$i]->{'Delay_Between_Requests'};
          }
        }

        if (defined $thisKey->[$i]->{'Delay_Between_Connections'}) {
          if (($thisKey->[$i]->{'Delay_Between_Connections'} >= 0) && ($thisKey->[$i]->{'Delay_Between_Connections'} <= 600000)) {
            $thisHttpDelayBetweenSessions = $thisKey->[$i]->{'Delay_Between_Connections'};
          }
        }

        $isAdaptive = 0;
        if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}) {
          $isAdaptive = 1;

          $thisHttpAdaptiveClientType = "Apple HLS";
          if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Client_Type'}) {
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Client_Type'}) eq "apple hls") {
                $thisHttpAdaptiveClientType = "Apple HLS";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Client_Type'}) eq "adobe flash hds") {
                $thisHttpAdaptiveClientType = "Adobe Flash HDS";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Client_Type'}) eq "microsoft smooth streaming") {
                $thisHttpAdaptiveClientType = "Microsoft Smooth Streaming";
             }
          }

          $thisHttp_AdaptiveStreamingMethod = "Monitor Fragment Retrieval Time";
          if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Streaming_Method'}) {
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Streaming_Method'}) eq "none") {
                $thisHttp_AdaptiveStreamingMethod = "None";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Streaming_Method'}) eq "monitor fragment bit rate") {
                $thisHttp_AdaptiveStreamingMethod = "Monitor Fragment Bit Rate";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Http_Adaptive_Streaming_Method'}) eq "monitor fragment retrieval time") {
                $thisHttp_AdaptiveStreamingMethod = "Monitor Fragment Retrieval Time";
             }
          }

          $thisShiftUpThreshold = "40";
          if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Up_Threshold'}) {
             if (($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Up_Threshold'} ne "") && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Up_Threshold'} >= 1) && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Up_Threshold'} <= 100)) {
                $thisShiftUpThreshold = $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Up_Threshold'};
             }
          }

          $thisShiftDownThreshold = "90";
          if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Down_Threshold'}) {
             if (($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Down_Threshold'} ne "") && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Down_Threshold'} >= 1) && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Down_Threshold'} <= 100)) {
                $thisShiftDownThreshold = $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Shift_Down_Threshold'};
                if ($thisShiftUpThreshold >= $thisShiftDownThreshold) {
                   $thisShiftUpThreshold = $thisShiftDownThreshold - 1;
                }
             }
          }

          $thisFragmentDownloadAlgorithm = "Playout Buffer";
          $thisPlayoutBufferDelay = "30";
          $thisDelayBetweenFragments = "";
          if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Fragment_Download_Algorithm'}) {
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Fragment_Download_Algorithm'}) eq "no delay") {
                $thisFragmentDownloadAlgorithm = "No Delay";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Fragment_Download_Algorithm'}) eq "at fragment play rate") {
                $thisFragmentDownloadAlgorithm = "At Fragment Play Rate";
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Fragment_Download_Algorithm'}) eq "playout buffer") {
                $thisFragmentDownloadAlgorithm = "Playout Buffer";
                if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Playout_Buffer_Delay'}) {
                   if (($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Playout_Buffer_Delay'} ne "") && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Playout_Buffer_Delay'} >= 1) && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Playout_Buffer_Delay'} <= 3600)) {
                      $thisPlayoutBufferDelay = $thisKey->[$i]->{'Playout_Buffer_Delay'};
                   }
                }
             }
             if (lc($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Fragment_Download_Algorithm'}) eq "delay between fragments") {
                $thisFragmentDownloadAlgorithm = "Delay between Fragments";
                if (defined $thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Delay_Between_Fragments'}) {
                   if (($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Delay_Between_Fragments'} ne "") && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Delay_Between_Fragments'} >= 1) && ($thisKey->[$i]->{'Http_Adaptive_Streaming'}->{'Delay_Between_Fragments'} <= 3600)) {
                      $thisDelayBetweenFragments = $thisKey->[$i]->{'Delay_Between_Fragments'};
                   }
                }
             }
          }
        }

        for $pdn (0..$PDNs_per_UE-1) {

          if ($Alias eq $defaultHttpAlias) {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
          }
          else {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_HTTP_PDN".$pdn;
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@HttpAliasNames) == 0) {
            push(@HttpAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (index($thisKey->[$i]->{'Path'}, "%UE_ID") != -1) {
                  $command_list = $Alias."_ue".$ue."_pdn".sprintf("%s", $pdn).$HttpRequestListId.$suffix;
                }
                else {
                  $listRangeStr = $rangeStr;
                  $nameLen = length($Alias.$rangeStr.$HttpRequestListId.$suffix);
                  if ($nameLen > 32) {
                     $rangeLen = 32 - length($Alias.$HttpRequestListId.$suffix);
                     if ($rangeLen > 0) {
                        $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                     }
                     else {
                        $listRangeStr = "";
                     }
                  }
                  $command_list = $Alias.$listRangeStr.$HttpRequestListId.$suffix;
                }

                $thisTempHttpUsername = $thisHttpUsername;
                $thisTempHttpPassword = $thisHttpPassword;

                if (index($thisTempHttpUsername, "%UE_ID%") != -1) {
                  ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempHttpUsername, 2);
                  $thisTempHttpUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_httpuser_".$overrideName);
                }
                if (index($thisTempHttpPassword, "%UE_ID%") != -1) {
                  ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempHttpPassword, 2);
                  $thisTempHttpPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_httppass_".$overrideName);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {

                  $rawThisUeRange = $thisUeRange;

                  $Tg->NewTemplate();
                  $mtmoStr = "";
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn, $mtmoStr);

                  $prefixLabel = $Alias."_";
                  $suffixLabel = "_".$pdn;

                  if (defined $thisKey->[$i]->{'Server_Host_Name'}) {

                    $thisHostName = $thisKey->[$i]->{'Server_Host_Name'};
                    if (index($thisKey->[$i]->{'Server_Host_Name'}, "%UE_ID") != -1) {
                      $ueStep = index($thisKey->[$i]->{'Server_Host_Name'}, "+");
                      if ($ueStep != -1) {
                        $ueStep = $thisKey->[$i]->{'Server_Host_Name'};
                        $ueStep =~ /\%(.*?)\%/;
                        $ueStep = $1;
                        $matchStr = "%".$1."%";
                        $ueStep =~ s/[^0-9]//g;
                      }
                      else {
                        $ueStep = 0;
                        $matchStr = "%UE_ID%";
                      }

                      $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'};

                      $thisHttpServer =~ s/%PDN%/pdn$pdn/g;
                      $thisUeRange =~ s/-/\.\./g;
                      if ($thisUeRange =~ m/\.\./) {
                        ($minVal, $maxVal) = split('\.\.', $thisUeRange);
                        if ($maxVal eq "") { # for the case "x.."
                          $maxVal = $conf{UEs};
                        }
                        $thisUeRange = $minVal."-".$maxVal;
                      }
                      ($strPrefix, $strMiddle, $strSuffix) = split('\%', $thisHttpServer, 3);
                      $strMiddle = "";
                      if (!(defined($strSuffix))) {
                        $strSuffix = "";
                      }

                      if ($ueStep == 0) {
                        $oddEvenStr = "";
                      }
                      elsif ($ueStep % 2) {
                        if (lc($oddOrEvenOrNone) eq "even") {
                          $oddEvenStr = "_odd";
                        }
                        else {
                          $oddEvenStr = "_even";
                        }
                      }
                      else {
                        if (lc($oddOrEvenOrNone) eq "odd") {
                            $oddEvenStr = "_odd";
                        }
                        else {
                            $oddEvenStr = "_even";
                        }
                      }

                      if ($mtmoStr ne "") {
                        $mtmoStr = "_mt";
                      }

                      $thisHttpServer = diversifEye::PsScaled->new(scaled_entity=>$strPrefix.$thisUeRange.$oddEvenStr.$mtmoStr.$strSuffix);
                    }
                    elsif ((grep /^$thisHostName/,@ServerNames) == 0) {
                      $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'};
                    }
                    else {
                      if ($thisUseTLS eq "true") {
                        $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'}."_https";
                      }
                      else {
                        $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'}."_http";
                      }
                    }
                  }

                  if ((grep /^$thisHttpServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$rawThisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$rawThisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  if ($isAdaptive) {
                      $Tg->Add(diversifEye::HttpAdaptiveClient->
                      new(scale_factor=>$scaleFactor,
                      name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                      description=>$thisHttpDescription,
                      host=>$thisHost,
                      server=>$thisHttpServer,
                      manifest_request_list=>$command_list,
                      http_username=>$thisTempHttpUsername,
                      http_password=>$thisTempHttpPassword,
                      adaptive_bit_rate_client_type=>$thisHttpAdaptiveClientType,
                      initial_stream_selection=>'First in Manifest',
                      adaptive_streaming_method=>$thisHttp_AdaptiveStreamingMethod,
                      adaptive_change_interval=>1,
                      adaptive_change_interval_metric=>'secs',
                      adaptive_streaming_shift_up_threshold=>$thisShiftUpThreshold,
                      adaptive_streaming_shift_down_threshold=>$thisShiftDownThreshold,
                      fragment_download_algorithm=>$thisFragmentDownloadAlgorithm,
                      playout_buffer_delay=>$thisPlayoutBufferDelay,
                      delay_between_fragments=>$thisDelayBetweenFragments,
                      delay_between_fragments_metric=>'ms',
                      delay_between_sessions=>$thisHttpDelayBetweenSessions,
                      delay_between_sessions_metric=>'ms',
                      is_normal_stats_enabled=>$NormalStatsEnabled,
                      is_fine_stats_enabled=>$FineStatsEnabled,
                      is_http_response_code_stats_enabled=>'true',
                      aggregate_group=>$thisAggregateGroupName,
                      tcp_characteristics=>$TcpCharacteristicsName,
                      service_state=>$ServiceState,
                      administrative_state=>$AsOther));
                  }
                  else {
                     $Tg->Add(diversifEye::HttpClient->new(scale_factor=>$scaleFactor,
                       name=>diversifEye::PsAlnum->new(prefix_label=>$prefixLabel, suffix_label=>$suffixLabel, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                       enable_tls=>$thisUseTLS,
                       description=>$thisHttpDescription,
                       host=>$thisHost,
                       is_normal_stats_enabled=>$NormalStatsEnabled,
                       is_fine_stats_enabled=>$FineStatsEnabled,
                       aggregate_group=>$thisAggregateGroupName,
                       tcp_characteristics=>$TcpCharacteristicsName,
                       server=>$thisHttpServer,
                       requested_list=>$command_list,
                       authentication_user=>$thisTempHttpUsername,
                       authentication_password=>$thisTempHttpPassword,
                       delay_between_requests=>$thisHttpDelayBetweenCommands,
                       delay_between_requests_metric=>'ms',
                       delay_between_connections=>$thisHttpDelayBetweenSessions,
                       delay_between_connections_metric=>'ms',
                       service_state=>$ServiceState,
                       administrative_state=>$AsOther));
                  }

                }
              }
            }
            else {

              for $ue (0..$conf{UEs}-1) {

                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);

                  if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
                    if (index($thisKey->[$i]->{'Server_Host_Name'}, "%UE_ID") != -1) {
                      $ueStep = index($thisKey->[$i]->{'Server_Host_Name'}, "+");
                      if ($ueStep != -1) {
                        $ueStep = $thisKey->[$i]->{'Server_Host_Name'};
                        $ueStep =~ /\%(.*?)\%/;
                        $ueStep = $1;
                        $matchStr = "%".$1."%";
                        $ueStep =~ s/[^0-9]//g;
                      }
                      else {
                        $ueStep = 0;
                        $matchStr = "%UE_ID%";
                      }
                      $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'};
                      if (($UeRange eq "") || (isInRange(($ue * 1) + ($ueStep * 1), $UeRange) == 1))
                      {
                        $ueStrWithStep = sprintf("%0${MinimumUeIdDigits}s", ($ue * 1) + ($ueStep * 1));
                      }
                      else
                      {
                        $minVal = 0;
                        if ($UeRange ne "") {
                          $thisRange = $UeRange;
                          $thisRange =~ s/-/\.\./g;
                          if (index($UeRange, ",") != -1) {
                            @UeGroups = split(",", $thisRange);
                          }
                          else {
                            push(@UeGroups, $thisRange);
                          }
                          $thisRange = $UeGroups[0];
                          if ($thisRange =~ m/\.\./) {
                            ($minVal, $maxVal) = split('\.\.', $thisRange);
                          }
                          else {
                            $minVal = $thisRange;
                          }
                        }
                        $ueStrWithStep = sprintf("%0${MinimumUeIdDigits}s", ($minVal * 1) + ($ueStep * 1));
                      }
                      $thisHttpServer =~ s/\Q$matchStr\E/$ueStrWithStep/g;
                      $thisHttpServer =~ s/%PDN%/$pdn/g;

                      if (($thisUseTLS eq "true") && ($VERSION >= 8)) {
                        $thisHttpServer = $thisHttpServer."_https";
                      }
                      else {
                        #$thisHttpServer = $thisHttpServer."_http";
                      }

                    }
                    else {
                      if (($thisUseTLS eq "true") && ($VERSION >= 8)) {
                        $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'}."_https";
                      }
                      else {
                        $thisHttpServer = $thisKey->[$i]->{'Server_Host_Name'}."_http";
                      }
                    }
                  }

                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if (index($thisKey->[$i]->{'Path'}, "%UE_ID") != -1) {
                    $command_list = $Alias."_ue".$ue."_pdn".sprintf("%s", $pdn).$HttpRequestListId.$suffix;
                  }
                  else {
                    $listRangeStr = $rangeStr;
                    $nameLen = length($Alias.$rangeStr.$HttpRequestListId.$suffix);
                    if ($nameLen > 32) {
                       $rangeLen = 32 - length($Alias.$HttpRequestListId.$suffix);
                       if ($rangeLen > 0) {
                          $listRangeStr = substr($rangeStr, 0, $rangeLen-2)."..";
                       }
                       else {
                          $listRangeStr = "";
                       }
                    }
                    $command_list = $Alias.$listRangeStr.$HttpRequestListId.$suffix;
                  }

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ($LastHttpAliasName ne $AliasEntryName) {
                    $LastHttpAliasName = $AliasEntryName;
                    $Tg->NewTemplate();
                  }

                  $thisTempHttpUsername = $thisHttpUsername;
                  $thisTempHttpPassword = $thisHttpPassword;
                  $thisTempHttpUsername =~ s/%UE_ID%/$ueStr/g;
                  $thisTempHttpPassword =~ s/%UE_ID%/$ueStr/g;

                  if ($VERSION >= 8) {
                    if (($thisUseTLS eq "true") && ($ReduceOnOff eq "1")) {
                      $Tg->NewTemplate();
                    }
                    if ($isAdaptive) {
                       $Tg->Add(diversifEye::HttpAdaptiveClient->
                       new(name=>$Alias."_".$base_name,
                       description=>$thisHttpDescription,
                       host=>$host_name,
                       server=>$thisHttpServer,
                       manifest_request_list=>$command_list,
                       http_username=>$thisTempHttpUsername,
                       http_password=>$thisTempHttpPassword,
                       adaptive_bit_rate_client_type=>$thisHttpAdaptiveClientType,
                       initial_stream_selection=>'First in Manifest',
                       adaptive_streaming_method=>$thisHttp_AdaptiveStreamingMethod,
                       adaptive_change_interval=>1,
                       adaptive_change_interval_metric=>'secs',
                       adaptive_streaming_shift_up_threshold=>$thisShiftUpThreshold,
                       adaptive_streaming_shift_down_threshold=>$thisShiftDownThreshold,
                       fragment_download_algorithm=>$thisFragmentDownloadAlgorithm,
                       playout_buffer_delay=>$thisPlayoutBufferDelay,
                       delay_between_fragments=>$thisDelayBetweenFragments,
                       delay_between_fragments_metric=>'ms',
                       delay_between_sessions=>$thisHttpDelayBetweenSessions,
                       delay_between_sessions_metric=>'ms',
                       is_normal_stats_enabled=>$NormalStatsEnabled,
                       is_fine_stats_enabled=>$FineStatsEnabled,
                       is_http_response_code_stats_enabled=>'true',
                       aggregate_group=>$thisAggregateGroupName,
                       tcp_characteristics=>$TcpCharacteristicsName,
                       service_state=>$ServiceState,
                       administrative_state=>$AsOther));
                    }
                    else {
                       $Tg->Add(diversifEye::HttpClient->
                       new (name=>$Alias."_".$base_name,
                       enable_tls=>$thisUseTLS,
                       description=>$thisHttpDescription,
                       host=>$host_name,
                       is_normal_stats_enabled=>$NormalStatsEnabled,
                       is_fine_stats_enabled=>$FineStatsEnabled,
                       aggregate_group=>$thisAggregateGroupName,
                       tcp_characteristics=>$TcpCharacteristicsName,
                       server=>$thisHttpServer,
                       requested_list=>$command_list,
                       authentication_user=>$thisTempHttpUsername,
                       authentication_password=>$thisTempHttpPassword,
                       delay_between_requests=>$thisHttpDelayBetweenCommands,
                       delay_between_requests_metric=>'ms',
                       delay_between_connections=>$thisHttpDelayBetweenSessions,
                       delay_between_connections_metric=>'ms',
                       service_state=>$ServiceState,
                       administrative_state=>$AsOther));
                    }
                  }
                  else {
                    $Tg->Add(diversifEye::HttpClient->
                    new (name=>$Alias."_".$base_name,
                    description=>$thisHttpDescription,
                    host=>$host_name,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisHttpServer,
                    requested_list=>$command_list,
                    authentication_user=>$thisTempHttpUsername,
                    authentication_password=>$thisTempHttpPassword,
                    delay_between_requests=>$thisHttpDelayBetweenCommands,
                    delay_between_requests_metric=>'ms',
                    delay_between_connections=>$thisHttpDelayBetweenSessions,
                    delay_between_connections_metric=>'ms',
                    service_state=>$ServiceState,
                    administrative_state=>$AsOther));
                  }
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }





  #
  #   RTSP Client
  #
  if ((defined $loadProfilesKey->{'RTSP'}) && ($RtspEnabled eq 1)) {
    printf(STDERR "%s\n", 'Generating RTSP Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'RTSP'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultRtspAlias;
      }


      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultRtspAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharRtspId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisRtspDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisRtspDescription = $defaultRtspDescription;  # The default description
        }

        $thisRtspServer = $RtspServer;
        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisRtspServer = $thisKey->[$i]->{'Server_Host_Name'}."_rtsp";
        }

        $thisRtspUseInitialAuthentication = 'false';
        $thisRtspUsername = $RtspUsername;
        if (defined $thisKey->[$i]->{'Username'}) {
          $thisRtspUsername = $thisKey->[$i]->{'Username'};

          if (defined $thisKey->[$i]->{'Use_Initial_Authentication'}) {
            if ($thisKey->[$i]->{'Use_Initial_Authentication'} eq 'true') {
              $thisRtspUseInitialAuthentication = 'true';
            }
          }
        }

        $thisRtspPassword = $RtspPassword;
        if (defined $thisKey->[$i]->{'Password'}) {
          $thisRtspPassword = $thisKey->[$i]->{'Password'};
        }

        $thisRtspDelayBetweenSessions = $RtspDelayBetweenSessions;
        if (defined $thisKey->[$i]->{'Delay_Between_Sessions'}) {
          $thisRtspDelayBetweenSessions = $thisKey->[$i]->{'Delay_Between_Sessions'};
        }

        $thisRtspMediaStreamMethod = 'UDP';
        if (defined $thisKey->[$i]->{'Media_Stream_Method'}) {
          if ($thisKey->[$i]->{'Media_Stream_Method'} eq 'TCP') {
            $thisRtspMediaStreamMethod = 'TCP';
          }
        }

        $thisRtspMediaTransport = 'RTP';
        if (defined $thisKey->[$i]->{'Media_Transport'}) {
          if ($thisKey->[$i]->{'Media_Transport'} eq 'MPEG2-TS') {
            $thisRtspMediaTransport = 'MPEG2-TS';
          }
          elsif ($thisKey->[$i]->{'Media_Transport'} eq 'MPEG2-TS/RTP') {
            $thisRtspMediaTransport = 'MPEG2-TS/RTP';
          }
        }

        $thisRtspMediaInactivityTimeout = $RtspMediaInactivityTimeout;
        if (defined $thisKey->[$i]->{'Media_Inactivity_Timeout'}) {
          $thisRtspMediaInactivityTimeout = $thisKey->[$i]->{'Media_Inactivity_Timeout'};
        }

        $thisRtspMediaStreamDuration = $RtspMediaStreamDuration;
        if (defined $thisKey->[$i]->{'Media_Stream_Duration'}) {
          if ($thisKey->[$i]->{'Media_Stream_Duration'} eq 'Time') {
            $thisRtspMediaStreamDuration = 'Period of Time';
          }
          elsif ($thisKey->[$i]->{'Media_Stream_Duration'} eq 'Data') {
            $thisRtspMediaStreamDuration = 'Amount of Data';
          }
          elsif ($thisKey->[$i]->{'Media_Stream_Duration'} eq 'Indefinite') {
            $thisRtspMediaStreamDuration = 'Indefinite';
          }
        }

        $thisRtspMediaStreamDurationPeriodOfTime = $RtspMediaStreamDurationPeriodOfTime;
        if (defined $thisKey->[$i]->{'Media_Stream_Duration_Period_of_Time'}) {
          $thisRtspMediaStreamDurationPeriodOfTime = $thisKey->[$i]->{'Media_Stream_Duration_Period_of_Time'};
        }

        $thisRtspMediaStreamAmountOfData = $RtspMediaStreamAmountOfData;
        if (defined $thisKey->[$i]->{'Media_Stream_Amount_Of_Data'}) {
          $thisRtspMediaStreamAmountOfData = $thisKey->[$i]->{'Media_Stream_Amount_Of_Data'};
        }

        $thisRtspStartAfter = $RtspStartAfter;
        if (defined $thisKey->[$i]->{'Start_After'}) {
          $thisRtspStartAfter = $thisKey->[$i]->{'Start_After'};
        }

        $thisRtspStopAfter = $RtspStopAfter;
        if (defined $thisKey->[$i]->{'Stop_After'}) {
          $thisRtspStopAfter = $thisKey->[$i]->{'Stop_After'};
        }

        $mediaPorts = $RtspPortProfileDefault;
        if (defined $thisKey->[$i]->{'Media_Port'}) {
          $thisMediaPorts = $thisKey->[$i]->{'Media_Port'};
          $thisMediaPorts =~ s/\.\./-/g;  # change .. to -
          if ($thisMediaPorts =~ m/\-/) {
            $mediaPorts = "Rtsp_".$thisMediaPorts;
          }
          else {
            $mediaPorts = $thisMediaPorts;
          }
        }

        # Do some quick checks based on the stream method.
        if ($thisRtspMediaStreamMethod eq 'TCP') {
          $mediaPorts = '';
          if ($thisRtspMediaTransport eq 'MPEG2-TS') {  # This is also only allowed in TCP mode.
            $thisRtspMediaTransport = 'MPEG2-TS/RTP';
          }
        }
        else {
          $TcpCharacteristicsName = ""; # Not allowed for UDP
        }

        $media_resources_list = $Alias.$rangeStr.$RtspRequestListId.$suffix;
        $rtp_port_profile = $RtpPortProfileDefault;

        $thisConfigurePassiveAnalysis = "false";
        $thisPaPlayoutJitter = "40";
        $thisPaMaxJitter = "80";
        $thisPaVideoCodec = "MPEG";
        $thisPaEnableAudioCodec = "false";
        $thisPaAudioCodec = "MPEG-1 Layer 1";
        $thisPaAutoDeterminePid = "true";
        $thisPaVideoPid = "";
        $thisPaAudioPid = "";
        $thisPaEnablePassiveAnalysisStats = "true";

        if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}) {
          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Playout_Jitter'}) {
            if (($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Playout_Jitter'} >= 0) && ($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Playout_Jitter'} <= 65535)) {
              $thisPaPlayoutJitter = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Playout_Jitter'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Max_Jitter'}) {
            if (($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Max_Jitter'} >= 0) && ($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Max_Jitter'} <= 65535)) {
              $thisPaMaxJitter = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Max_Jitter'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if ($thisPaPlayoutJitter > $thisPaMaxJitter) {
            $thisPaMaxJitter = $thisPaPlayoutJitter;
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Codec'}) {
            if (grep /$thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Codec'}/, @diversifEyePaRtpVideoCodecs) {
              $thisPaVideoCodec = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Codec'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Analyse_Audio_Stream'}) {
            if ($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Analyse_Audio_Stream'} eq 'true') {
              $thisPaEnableAudioCodec = 'true';
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Codec'}) {
            if (grep /$thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Codec'}/, @diversifEyePaRtpAudioCodecs) {
              $thisPaAudioCodec = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Codec'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Pid'}) {
            if (($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Pid'} >= 16) && ($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Pid'} <= 8192)) {
              $thisPaVideoPid = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Video_Pid'};
            }
          }

          if (defined $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Pid'}) {
            if (($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Pid'} >= 16) && ($thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Pid'} <= 8192)) {
              $thisPaAudioPid = $thisKey->[$i]->{'RTSP_Passive_Analysis'}->{'Audio_Pid'};
            }
          }

          if (($thisPaAudioPid ne "") && ($thisPaVideoPid ne "") && ($thisPaAudioPid ne $thisPaVideoPid)) {
            $thisPaAutoDeterminePid = "false";
          }
          else {
            $thisPaAudioPid = "";
            $thisPaVideoPid = "";
            $thisPaAutoDeterminePid = "true";
          }

        }

        for $pdn (0..$PDNs_per_UE-1) {

          if ($Alias eq $defaultRtspAlias) {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
          }
          else {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_RTSP_PDN".$pdn;
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@RtspAliasNames) == 0) {
            push(@RtspAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {
                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisTempRtspUsername = $thisRtspUsername;
                  $thisTempRtspPassword = $thisRtspPassword;
                  if ($thisRtspUseInitialAuthentication eq 'true') {
                    if (index($thisTempRtspUsername, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempRtspUsername, 2);
                      $thisTempRtspUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftpuser_".$overrideName);
                    }
                    if (index($thisTempRtspPassword, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisTempRtspPassword, 2);
                      $thisTempRtspPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$startingAt, increment_size=>$incrementSize, value_override=>$strPrefix."_".$strSuffix."_ftppass_".$overrideName);
                    }
                  }

                  if ((grep /^$thisRtspServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->Add(diversifEye::RtspClient->new (scale_factor=>$scaleFactor,
                    name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                    description=>$thisRtspDescription,
                    host=>$thisHost,
                    start_after=>$thisRtspStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisRtspStopAfter,
                    stop_after_metric=>"secs",
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisRtspServer,
                    media_resources_requested=>$media_resources_list,
                    rtsp_username=>$thisTempRtspUsername,
                    rtsp_password=>$thisTempRtspPassword,
                    initial_authentication=>$thisRtspUseInitialAuthentication,
                    media_transport_method=>$thisRtspMediaTransport,
                    media_stream_method=>$thisRtspMediaStreamMethod,
                    inactivity_timeout=>$thisRtspMediaInactivityTimeout,
                    inativity_timeout_metric=>"ms",
                    media_stream_duration=>$thisRtspMediaStreamDuration,
                    amount_data=>$thisRtspMediaStreamAmountOfData,
                    amount_data_metric=>"KiB",
                    period_time=>$thisRtspMediaStreamDurationPeriodOfTime,
                    period_time_metric=>"ms",
                    media_ports=>$mediaPorts,
                    delay_between_sessions=>$thisRtspDelayBetweenSessions,
                    delay_between_sessions_metric=>"ms",
                    service_state=>$ServiceState,
                    configure_passive_analysis=>$thisConfigurePassiveAnalysis,
                    playout_jitter=>$thisPaPlayoutJitter,
                    playout_jitter_metric=>"ms",
                    max_jitter=>$thisPaMaxJitter,
                    max_jitter_metric=>"ms",
                    enabled_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                    video_codec=>$thisPaVideoCodec,
                    analyse_audio_stream=>$thisPaEnableAudioCodec,
                    audio_codec=>$thisPaAudioCodec,
                    auto_determine_pid=>$thisPaAutoDeterminePid,
                    video_pid=>$thisPaVideoPid,
                    audio_pid=>$thisPaAudioPid,
                    administrative_state=>$AsOther));
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {

                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ($LastRtspAliasName ne $AliasEntryName) {
                    $LastRtspAliasName = $AliasEntryName;
                    $Tg->NewTemplate();
                  }

                  $thisTempRtspUsername = $thisRtspUsername;
                  $thisTempRtspPassword = $thisRtspPassword;
                  if ($thisRtspUseInitialAuthentication eq 'true') {
                    $thisTempRtspUsername =~ s/%UE_ID%/$ueStr/g;
                    $thisTempRtspPassword =~ s/%UE_ID%/$ueStr/g;
                  }


                  if ($VERSION >= 8.2) {
                    $Tg->Add(diversifEye::RtspClient->
                    new (name=>$Alias."_".$base_name,
                    description=>$thisRtspDescription,
                    host=>$host_name,
                    start_after=>$thisRtspStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisRtspStopAfter,
                    stop_after_metric=>"secs",
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisRtspServer,
                    media_resources_requested=>$media_resources_list,
                    rtsp_username=>$thisTempRtspUsername,
                    rtsp_password=>$thisTempRtspPassword,
                    initial_authentication=>$thisRtspUseInitialAuthentication,
                    media_transport_method=>$thisRtspMediaTransport,
                    media_stream_method=>$thisRtspMediaStreamMethod,
                    inactivity_timeout=>$thisRtspMediaInactivityTimeout,
                    inativity_timeout_metric=>"ms",
                    media_stream_duration=>$thisRtspMediaStreamDuration,
                    amount_data=>$thisRtspMediaStreamAmountOfData,
                    amount_data_metric=>"KiB",
                    period_time=>$thisRtspMediaStreamDurationPeriodOfTime,
                    period_time_metric=>"ms",
                    media_ports=>$mediaPorts,
                    delay_between_sessions=>$thisRtspDelayBetweenSessions,
                    delay_between_sessions_metric=>"ms",
                    service_state=>$ServiceState,
                    configure_passive_analysis=>$thisConfigurePassiveAnalysis,
                    playout_jitter=>$thisPaPlayoutJitter,
                    playout_jitter_metric=>"ms",
                    max_jitter=>$thisPaMaxJitter,
                    max_jitter_metric=>"ms",
                    enabled_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                    video_codec=>$thisPaVideoCodec,
                    analyse_audio_stream=>$thisPaEnableAudioCodec,
                    audio_codec=>$thisPaAudioCodec,
                    auto_determine_pid=>$thisPaAutoDeterminePid,
                    video_pid=>$thisPaVideoPid,
                    audio_pid=>$thisPaAudioPid,
                    administrative_state=>$AsOther));
                  }
                  else {
                    $Tg->Add(diversifEye::RtspClient->
                    new (name=>$Alias."_".$base_name,
                    description=>$thisRtspDescription,
                    host=>$host_name,
                    start_after=>$thisRtspStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisRtspStopAfter,
                    stop_after_metric=>"secs",
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisRtspServer,
                    rtp_ports=>$rtp_port_profile,
                    media_resources_requested=>$media_resources_list,
                    rtsp_username=>$thisTempRtspUsername,
                    rtsp_password=>$thisTempRtspPassword,
                    initial_authentication=>$thisRtspUseInitialAuthentication,
                    media_transport_method=>$thisRtspMediaTransport,
                    media_stream_method=>$thisRtspMediaStreamMethod,
                    inactivity_timeout=>$thisRtspMediaInactivityTimeout,
                    inativity_timeout_metric=>"ms",
                    media_stream_duration=>$thisRtspMediaStreamDuration,
                    amount_data=>$thisRtspMediaStreamAmountOfData,
                    amount_data_metric=>"KiB",
                    period_time=>$thisRtspMediaStreamDurationPeriodOfTime,
                    period_time_metric=>"ms",
                    media_ports=>$mediaPorts,
                    delay_between_sessions=>$thisRtspDelayBetweenSessions,
                    delay_between_sessions_metric=>"ms",
                    service_state=>$ServiceState,
                    administrative_state=>$AsOther));
                  }
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }




  #
  #   TWAMP Client
  #
  if ((defined $loadProfilesKey->{'TWAMP'}) && ($TwampEnabled eq 1)) {
    printf(STDERR "%s\n", 'Generating TWAMP Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TWAMP'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultTwampAlias;
      }


      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) || (defined $thisKey->[$i]->{'Path'})) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultTwampAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharTwampId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisTwampDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisTwampDescription = $defaultTwampDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisTwampServer = $thisKey->[$i]->{'Server_Host_Name'}."_twamp";
        }

        $thisControlPort = "";
        if (defined $thisKey->[$i]->{'Control_Port'}) {
          if (($thisKey->[$i]->{'Control_Port'} ne "") && ($thisKey->[$i]->{'Control_Port'} > 0) && ($thisKey->[$i]->{'Control_Port'} <= 65535)) {
            $thisControlPort = $thisKey->[$i]->{'Control_Port'};
          }
        }

        $thisControlQoS = "0";
        if (defined $thisKey->[$i]->{'Control_QoS'}) {
          if (($thisKey->[$i]->{'Control_QoS'} ne "") && ($thisKey->[$i]->{'Control_QoS'} >= 0) && ($thisKey->[$i]->{'Control_QoS'} <= 255)) {
            $thisControlQoS = $thisKey->[$i]->{'Control_QoS'};
          }
        }

        $thisSourcePort = "";
        if (defined $thisKey->[$i]->{'Source_Port'}) {
          if (($thisKey->[$i]->{'Source_Port'} ne "") && ($thisKey->[$i]->{'Source_Port'} > 0) && ($thisKey->[$i]->{'Source_Port'} <= 65535)) {
            $thisSourcePort = $thisKey->[$i]->{'Source_Port'};
          }
        }

        $thisDestinationPort = "";
        if (defined $thisKey->[$i]->{'Destination_Port'}) {
          if (($thisKey->[$i]->{'Destination_Port'} ne "") && ($thisKey->[$i]->{'Destination_Port'} > 0) && ($thisKey->[$i]->{'Destination_Port'} <= 65535)) {
            $thisDestinationPort = $thisKey->[$i]->{'Destination_Port'};
          }
        }

        $thisSessionQoS = "0";
        if (defined $thisKey->[$i]->{'Session_QoS'}) {
          if (($thisKey->[$i]->{'Session_QoS'} ne "") && ($thisKey->[$i]->{'Session_QoS'} >= 0) && ($thisKey->[$i]->{'Session_QoS'} <= 255)) {
            $thisSessionQoS = $thisKey->[$i]->{'Session_QoS'};
          }
        }

        $thisDelayBetweenPackets = "100";
        if (defined $thisKey->[$i]->{'Delay_Between_Packets'}) {
          if (($thisKey->[$i]->{'Delay_Between_Packets'} ne "") && ($thisKey->[$i]->{'Delay_Between_Packets'} >= 1) && ($thisKey->[$i]->{'Delay_Between_Packets'} <= 3600000)) {
            $thisDelayBetweenPackets = $thisKey->[$i]->{'Delay_Between_Packets'};
          }
        }

        $thisPayloadSize = "100";
        if (defined $thisKey->[$i]->{'Payload_Size'}) {
          if (($thisKey->[$i]->{'Payload_Size'} ne "") && ($thisKey->[$i]->{'Payload_Size'} >= 41) && ($thisKey->[$i]->{'Payload_Size'} <= 1464)) {
            $thisPayloadSize = $thisKey->[$i]->{'Payload_Size'};
          }
        }


        $thisIndefiniteSessionDuration = "false";
        if (defined $thisKey->[$i]->{'Indefinite_Session_Duration'}) {
          if ($thisKey->[$i]->{'Indefinite_Session_Duration'} eq "true") {
            $thisIndefiniteSessionDuration = "true";
          }
        }

        $thisSessionDuration = "900";
        if (defined $thisKey->[$i]->{'Session_Duration'}) {
          if (($thisKey->[$i]->{'Session_Duration'} ne "") && ($thisKey->[$i]->{'Session_Duration'} >= 1) && ($thisKey->[$i]->{'Session_Duration'} <= 3600000000)) {
            $thisSessionDuration = $thisKey->[$i]->{'Session_Duration'};
          }
        }


        $thisSessionTimeout = "0";
        if (defined $thisKey->[$i]->{'Session_Timeout'}) {
          if (($thisKey->[$i]->{'Session_Timeout'} ne "") && ($thisKey->[$i]->{'Session_Timeout'} >= 0) && ($thisKey->[$i]->{'Session_Timeout'} <= 3600)) {
            $thisSessionTimeout = $thisKey->[$i]->{'Session_Timeout'};
          }
        }

      for $pdn (0..$PDNs_per_UE-1) {

        if ($Alias eq $defaultTwampAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_TWAMP_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@TwampAliasNames) == 0) {
          push(@TwampAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

            }
            else {
              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  $Tg->NewTemplate();

                  $Tts = diversifEye::TwampTestSession->new(
                     session_qos=>$thisSessionQoS,
                     session_udp_source_port=>$thisSourcePort,
                     use_session_src_port_for_dst_port=>"true",
                     session_udp_destination_port=>$thisDestinationPort,
                     session_duration=>$thisSessionDuration,
                     session_duration_metric=>"ms",
                     payload_size=>$thisPayloadSize,
                     infinite_session_duration_enabled=>$thisIndefiniteSessionDuration,
                     delay_between_packets=>$thisDelayBetweenPackets,
                     delay_between_packets_metric=>"ms",
                     session_timeout=>$thisSessionTimeout,
                     session_timeout_metric=>"secs");

                  $Tg->Add(diversifEye::TwampClient->
                  new (name=>$Alias."_".$base_name,
                  description=>$thisTwampDescription,
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther,
                  host=>$host_name,
                  control_tcp_port=>$thisControlPort,
                  control_qos=>$thisControlQoS,
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  aggregate_group=>$thisAggregateGroupName,
                  tcp_characteristics=>$TcpCharacteristicsName,
                  server=>$thisTwampServer,
                  twamp_test_session=>$Tts));
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }



  #
  #   TeraFlow Client
  #
  if ((defined $loadProfilesKey->{'TeraFlow'}) && ($TeraFlowEnabled eq 1) && ($VERSION >= 10)) {
    printf(STDERR "%s\n", 'Generating Teraflow Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'TeraFlow'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultTeraFlowAlias;
      }

      $ServerOnPPPoE = 0;
      if ((defined $thisKey->[$i]->{'Server_on_PPPoE'}) && (defined $thisKey->[$i]->{'Server_Host_Name'})) {
        $thisTfServerHostName = $thisKey->[$i]->{'Server_Host_Name'}."_tf";
        if ((lc($thisKey->[$i]->{'Server_on_PPPoE'}) eq "true") && ((grep /^$thisTfServerHostName/,@InternalTFServerNames) == 0)) {
          $ServerOnPPPoE = 1;
        }
      }

      if ((defined $thisKey->[$i]->{'Server_Host_Name'}) && ($ServerOnPPPoE == 0) ) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultTeraFlowAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharTeraFlowId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisTeraFlowDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisTeraFlowDescription = $defaultTeraFlowDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisTeraFlowServer = $thisKey->[$i]->{'Server_Host_Name'}."_tf";
        }

        $thisProtocol = "UDP";
        if (defined $thisKey->[$i]->{'TeraFlow_Transport_Type'}) {
          if (lc($thisKey->[$i]->{'TeraFlow_Transport_Type'}) eq "tcp") {
            $thisProtocol = "TCP";
          }
        }

        $thisTransportPort = "";
        if (defined $thisKey->[$i]->{'TeraFlow_Transport_Port'}) {
          if (($thisKey->[$i]->{'TeraFlow_Transport_Port'} ne "") && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} >= 1) && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} <= 65535)) {
            $thisTransportPort = $thisKey->[$i]->{'TeraFlow_Transport_Port'};
          }
        }

        $thisStartAfter = 0;
        if (defined $thisKey->[$i]->{'Start_After'}) {
          if (($thisKey->[$i]->{'Start_After'} ne "") && ($thisKey->[$i]->{'Start_After'} >= 0) && ($thisKey->[$i]->{'Start_After'} <= 3600000)) {
            $thisStartAfter = $thisKey->[$i]->{'Start_After'};
          }
        }

        $thisStopAfter = "";
        if (defined $thisKey->[$i]->{'Stop_After'}) {
          if (($thisKey->[$i]->{'Stop_After'} ne "") && ($thisKey->[$i]->{'Stop_After'} >= 1) && ($thisKey->[$i]->{'Stop_After'} <= 86400)) {
            $thisStopAfter = $thisKey->[$i]->{'Stop_After'};
          }
        }

        $thisPayloadSize = 8192;
        if (defined $thisKey->[$i]->{'TeraFlow_Payload_Size'}) {
          if (($thisKey->[$i]->{'TeraFlow_Payload_Size'} ne "") && ($thisKey->[$i]->{'TeraFlow_Payload_Size'} >= 1) && ($thisKey->[$i]->{'TeraFlow_Payload_Size'} <= 65535)) {
            $thisPayloadSize = $thisKey->[$i]->{'TeraFlow_Payload_Size'};
          }
        }

        $thisThroughputMetric = "Mbit/s";
        $thisThroughputMax = 10000000;
        if (defined $thisKey->[$i]->{'Throughput_Metric'}) {
          if (lc($thisKey->[$i]->{'Throughput_Metric'}) eq "bps") {
            $thisThroughputMetric = "bit/s";
            $thisThroughputMax = 10000000000000;
          }
          elsif (lc($thisKey->[$i]->{'Throughput_Metric'}) eq "kbps") {
            $thisThroughputMetric = "kbit/s";
            $thisThroughputMax = 10000000000;
          }
          elsif (lc($thisKey->[$i]->{'Throughput_Metric'}) eq "gbps") {
            $thisThroughputMetric = "Gbit/s";
            $thisThroughputMax = 10000;
          }
          elsif (lc($thisKey->[$i]->{'Throughput_Metric'}) eq "tbps") {
            $thisThroughputMetric = "Tbit/s";
            $thisThroughputMax = 10;
          }
        }

        $thisThroughput = 10;
        if (defined $thisKey->[$i]->{'Throughput'}) {
          if (($thisKey->[$i]->{'Throughput'} ne "") && ($thisKey->[$i]->{'Throughput'} >= 1) && ($thisKey->[$i]->{'Throughput'} <= $thisThroughputMax)) {
            $thisThroughput = $thisKey->[$i]->{'Throughput'};
          }
        }

        $thisNumberOfSessions = 1;
        if (defined $thisKey->[$i]->{'Number_of_Sessions'}) {
          if (($thisKey->[$i]->{'Number_of_Sessions'} ne "") && ($thisKey->[$i]->{'Number_of_Sessions'} >= 1) && ($thisKey->[$i]->{'Number_of_Sessions'} <= 100000000)) {
            $thisNumberOfSessions = $thisKey->[$i]->{'Number_of_Sessions'};
          }
        }

        $thisLatencyStats = $LatencyStatsEnabled;
        if (defined $thisKey->[$i]->{'Latency_Statistics'}) {
          if ($thisKey->[$i]->{'Latency_Statistics'} eq "true") {
            $thisLatencyStats = "true";
          }
          else {
            $thisLatencyStats = "false";
          }
        }

      for $pdn (0..$PDNs_per_UE-1) {

        if ($Alias eq $defaultTeraFlowAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_TF_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@TeraFlowAliasNames) == 0) {
          push(@TeraFlowAliasNames, $AliasEntryName);

          if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {
                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisNumberOfSessions = $scaleFactor;

                  if ((grep /^$thisTeraFlowServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $thisTfServerHostName = $thisKey->[$i]->{'Server_Host_Name'}."_tf";
                  if ((lc($thisKey->[$i]->{'Server_on_PPPoE'}) eq "true") && ((grep /^$thisTfServerHostName/,@InternalTFServerNames) != 0)) {
                    $thisHost = $thisTfServerHostName;
                    $thisTransportPort = "";
                    if ($Alias eq $defaultTeraFlowAlias) {
                      $thisTeraFlowServer = diversifEye::PsScaled->new(scaled_entity=>$defaultTeraFlowServerAlias."_".$overrideName);
                    }
                    else {
                      $thisTeraFlowServer = diversifEye::PsScaled->new(scaled_entity=>$Alias."_STF_".$overrideName);
                    }
                    foreach $key (keys %serverHosts) {
                      if ($key ne $thisHost) {
                        if ($serverHosts{$key} eq $serverHosts{$thisKey->[$i]->{'Server_Host_Name'}}) {
                          $thisHost = "Host_".$InternalTFServerIp{$thisTfServerHostName};
                          $thisHost =~ s/:/-/g;
                        }
                      }
                    }
                  }

                  $Tg->Add(diversifEye::TeraFlowClient->new (scale_factor=>$scaleFactor,
                    name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                    description=>$thisTeraFlowDescription,
                    service_state=>$ServiceState,
                    administrative_state=>$AsOther,
                    host=>$thisHost,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisTeraFlowServer,
                    transport_port=>$thisTransportPort,
                    protocol=>$thisProtocol,
                    number_of_sessions=>$thisNumberOfSessions,
                    throughput=>$thisThroughput,
                    throughput_metric=>$thisThroughputMetric,
                    payload_size=>$thisPayloadSize,
                    is_latency_stats_enabled=>$thisLatencyStats
                    ));

                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ($thisProtocol ne "TCP") {
                    $TcpCharacteristicsName = "";
                  }

                  $thisHostName = $host_name;
                  $thisTfServerHostName = $thisKey->[$i]->{'Server_Host_Name'}."_tf";
                  if ((lc($thisKey->[$i]->{'Server_on_PPPoE'}) eq "true") && ((grep /^$thisTfServerHostName/,@InternalTFServerNames) != 0)) {
                    $thisHostName = $thisTfServerHostName;
                    $thisTransportPort = "";
                    if ($Alias eq $defaultTeraFlowAlias) {
                      $thisTeraFlowServer = $defaultTeraFlowServerAlias."_".$base_name;
                    }
                    else {
                      $thisTeraFlowServer = $Alias."_STF_".$base_name;
                    }
                    foreach $key (keys %serverHosts) {
                      if ($key ne $host_name) {
                        if ($serverHosts{$key} eq $serverHosts{$thisKey->[$i]->{'Server_Host_Name'}}) {
                          $thisHostName = "Host_".$InternalTFServerIp{$thisTfServerHostName};
                          $thisHostName =~ s/:/-/g;
                        }
                      }
                    }
                  }

                  $Tg->NewTemplate();
                  if ($VERSION >= 10.2) {
                    $Tg->Add(diversifEye::TeraFlowClient->
                    new (name=>$Alias."_".$base_name,
                    description=>$thisTeraFlowDescription,
                    service_state=>$ServiceState,
                    administrative_state=>$AsOther,
                    host=>$thisHostName,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisTeraFlowServer,
                    transport_port=>$thisTransportPort,
                    protocol=>$thisProtocol,
                    number_of_sessions=>$thisNumberOfSessions,
                    throughput=>$thisThroughput,
                    throughput_metric=>$thisThroughputMetric,
                    payload_size=>$thisPayloadSize,
                    is_latency_stats_enabled=>$thisLatencyStats
                    ));
                  }
                  else {
                    $Tg->Add(diversifEye::TeraFlowClient->
                    new (name=>$Alias."_".$base_name,
                    description=>$thisTeraFlowDescription,
                    service_state=>$ServiceState,
                    administrative_state=>$AsOther,
                    host=>$host_name,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    tcp_characteristics=>$TcpCharacteristicsName,
                    server=>$thisTeraFlowServer,
                    transport_port=>$thisTransportPort,
                    protocol=>$thisProtocol,
                    number_of_sessions=>$thisNumberOfSessions,
                    throughput=>$thisThroughput,
                    throughput_metric=>$thisThroughputMetric,
                    payload_size=>$thisPayloadSize
                    ));
                  }
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }


  #
  #   MLD Client
  #
  if ((defined $loadProfilesKey->{'MLD'}) && ($MldEnabled eq 1) && ($VERSION >= 11)) {
    printf(STDERR "%s\n", 'Generating MLD Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'MLD'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultMldAlias;
      }

      if (defined $thisKey->[$i]->{'Server_Host_Name'}) {

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisMldDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisMldDescription = $defaultMldDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisMldServer = $thisKey->[$i]->{'Server_Host_Name'}."_mld";
        }

        $thisSourcePort = "";
        if (defined $thisKey->[$i]->{'Source_Port'}) {
          if (($thisKey->[$i]->{'Source_Port'} ne "") && ($thisKey->[$i]->{'Source_Port'} >= 1) && ($thisKey->[$i]->{'Source_Port'} <= 65535)) {
            $thisSourcePort = $thisKey->[$i]->{'Source_Port'};
          }
        }

        $thisDestinationPort = "";
        if (defined $thisKey->[$i]->{'Destination_Port'}) {
          if (($thisKey->[$i]->{'Destination_Port'} ne "") && ($thisKey->[$i]->{'Destination_Port'} >= 1) && ($thisKey->[$i]->{'Destination_Port'} <= 65535)) {
            $thisDestinationPort = $thisKey->[$i]->{'Destination_Port'};
          }
        }

        $thisMulticastGroupAddrerss = "";
        if (defined $thisKey->[$i]->{'Multicast_Group_Addrerss'}) {
          if ($thisKey->[$i]->{'Multicast_Group_Addrerss'} ne "") {
            $thisMulticastGroupAddrerss = $thisKey->[$i]->{'Multicast_Group_Addrerss'};
          }
        }

        $thisMediaTransport = "RTP";  # [RTP|MPEG2-TS/RTP|MPEG2-TS]
        if (defined $thisKey->[$i]->{'Media_Transport'}) {
          if (uc($thisKey->[$i]->{'Media_Transport'}) eq "MPEG2-TS/RTP") {
            $thisMediaTransport = "MPEG2-TS/RTP";
          }
          elsif (uc($thisKey->[$i]->{'Media_Transport'}) eq "MPEG2-TS") {
            $thisMediaTransport = "MPEG2-TS";
          }

        }

        $thisTransportPort = "";
        if (defined $thisKey->[$i]->{'TeraFlow_Transport_Port'}) {
          if (($thisKey->[$i]->{'TeraFlow_Transport_Port'} ne "") && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} >= 1) && ($thisKey->[$i]->{'TeraFlow_Transport_Port'} <= 65535)) {
            $thisTransportPort = $thisKey->[$i]->{'TeraFlow_Transport_Port'};
          }
        }

        $thisStartAfter = 0;
        if (defined $thisKey->[$i]->{'Start_After'}) {
          if (($thisKey->[$i]->{'Start_After'} ne "") && ($thisKey->[$i]->{'Start_After'} >= 0) && ($thisKey->[$i]->{'Start_After'} <= 3600000)) {
            $thisStartAfter = $thisKey->[$i]->{'Start_After'};
          }
        }

        $thisStopAfter = "";
        if (defined $thisKey->[$i]->{'Stop_After'}) {
          if (($thisKey->[$i]->{'Stop_After'} ne "") && ($thisKey->[$i]->{'Stop_After'} >= 1) && ($thisKey->[$i]->{'Stop_After'} <= 86400)) {
            $thisStopAfter = $thisKey->[$i]->{'Stop_After'};
          }
        }


      for $pdn (0..$PDNs_per_UE-1) {

        if ($Alias eq $defaultMldAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_MLD_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@MldAliasNames) == 0) {
          push(@MldAliasNames, $AliasEntryName);

          if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {
                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisNumberOfSessions = $scaleFactor;

                  if ((grep /^$thisMldServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_mld";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_mld".$v6suffix;
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->Add(diversifEye::MldClient->new(scale_factor=>$scaleFactor,
                  name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                  description=>$thisMldDescription,
                  host=>$thisHost,
                  start_after=>$thisStartAfter,
                  start_after_metric=>"ms",
                  stop_after=>$thisStopAfter,
                  stop_after_metric=>"secs",
                  media_transport=>$thisMediaTransport,
                  interested_group_selection=>'Specific Group',
                  interested_group_list=>$thisInterestedGroupList,
                  multicast_group_address=>$thisMulticastGroupAddrerss,
                  source_port=>$thisSourcePort,
                  destination_port=>$thisDestinationPort,
                  accept_from_any_src_port=>'false',
                  accept_to_any_dst_port=>'false',
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  enable_extended_leave_statistics=>"true",
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther
                  ));

                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);
                  if ((grep /^$thisMldServer/,@IpV6ServerHostNames) == 0) {
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_mld";
                  }
                  else {
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_mld".$v6suffix;
                  }

                  $Tg->NewTemplate();
                  $Tg->Add(diversifEye::MldClient->new(
                  name=>$Alias."_".$base_name,
                  description=>$thisMldDescription,
                  host=>$host_name,
                  start_after=>$thisStartAfter,
                  start_after_metric=>"ms",
                  stop_after=>$thisStopAfter,
                  stop_after_metric=>"secs",
                  media_transport=>$thisMediaTransport,
                  interested_group_selection=>'Specific Group',
                  interested_group_list=>$thisInterestedGroupList,
                  multicast_group_address=>$thisMulticastGroupAddrerss,
                  source_port=>$thisSourcePort,
                  destination_port=>$thisDestinationPort,
                  accept_from_any_src_port=>'false',
                  accept_to_any_dst_port=>'false',
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  enable_extended_leave_statistics=>"true",
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther
                  ));
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }


  #
  #   IGMP Client
  #
  if ((defined $loadProfilesKey->{'IGMP'}) && ($IgmpEnabled eq 1) && ($VERSION >= 11)) {
    printf(STDERR "%s\n", 'Generating IGMP Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'IGMP'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultIgmpAlias;
      }

      if (defined $thisKey->[$i]->{'Server_Host_Name'}) {

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisIgmpDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisIgmpDescription = $defaultIgmpDescription;  # The default description
        }

        if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
          $thisIgmpServer = $thisKey->[$i]->{'Server_Host_Name'}."_igmp";
        }

        $thisSourcePort = "";
        if (defined $thisKey->[$i]->{'Source_Port'}) {
          if (($thisKey->[$i]->{'Source_Port'} ne "") && ($thisKey->[$i]->{'Source_Port'} >= 1) && ($thisKey->[$i]->{'Source_Port'} <= 65535)) {
            $thisSourcePort = $thisKey->[$i]->{'Source_Port'};
          }
        }

        $thisDestinationPort = "";
        if (defined $thisKey->[$i]->{'Destination_Port'}) {
          if (($thisKey->[$i]->{'Destination_Port'} ne "") && ($thisKey->[$i]->{'Destination_Port'} >= 1) && ($thisKey->[$i]->{'Destination_Port'} <= 65535)) {
            $thisDestinationPort = $thisKey->[$i]->{'Destination_Port'};
          }
        }

        $thisMulticastGroupAddrerss = "";
        if (defined $thisKey->[$i]->{'Multicast_Group_Addrerss'}) {
          if ($thisKey->[$i]->{'Multicast_Group_Addrerss'} ne "") {
            $thisMulticastGroupAddrerss = $thisKey->[$i]->{'Multicast_Group_Addrerss'};
          }
        }

        $thisMediaTransport = "RTP";  # [RTP|MPEG2-TS/RTP|MPEG2-TS]
        if (defined $thisKey->[$i]->{'Media_Transport'}) {
          if (uc($thisKey->[$i]->{'Media_Transport'}) eq "MPEG2-TS/RTP") {
            $thisMediaTransport = "MPEG2-TS/RTP";
          }
          elsif (uc($thisKey->[$i]->{'Media_Transport'}) eq "MPEG2-TS") {
            $thisMediaTransport = "MPEG2-TS";
          }
        }

        $thisStartAfter = 0;
        if (defined $thisKey->[$i]->{'Start_After'}) {
          if (($thisKey->[$i]->{'Start_After'} ne "") && ($thisKey->[$i]->{'Start_After'} >= 0) && ($thisKey->[$i]->{'Start_After'} <= 3600000)) {
            $thisStartAfter = $thisKey->[$i]->{'Start_After'};
          }
        }

        $thisStopAfter = "";
        if (defined $thisKey->[$i]->{'Stop_After'}) {
          if (($thisKey->[$i]->{'Stop_After'} ne "") && ($thisKey->[$i]->{'Stop_After'} >= 1) && ($thisKey->[$i]->{'Stop_After'} <= 86400)) {
            $thisStopAfter = $thisKey->[$i]->{'Stop_After'};
          }
        }

      for $pdn (0..$PDNs_per_UE-1) {

        if ($Alias eq $defaultIgmpAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_IGMP_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@IgmpAliasNames) == 0) {
          push(@IgmpAliasNames, $AliasEntryName);

          if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {
                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  $thisNumberOfSessions = $scaleFactor;

                  if ((grep /^$thisIgmpServer/,@IpV6ServerHostNames) == 0) {
                    $pppoeStr = "pppoe_";
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_Igmp";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_Igmp".$v6suffix;
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->Add(diversifEye::IgmpClient->new(scale_factor=>$scaleFactor,
                  name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                  description=>$thisIgmpDescription,
                  host=>$thisHost,
                  start_after=>$thisStartAfter,
                  start_after_metric=>"ms",
                  stop_after=>$thisStopAfter,
                  stop_after_metric=>"secs",
                  media_transport=>$thisMediaTransport,
                  interested_group_selection=>'Specific Group',
                  interested_group_list=>$thisInterestedGroupList,
                  multicast_group_address=>$thisMulticastGroupAddrerss,
                  source_port=>$thisSourcePort,
                  destination_port=>$thisDestinationPort,
                  accept_from_any_src_port=>'false',
                  accept_to_any_dst_port=>'false',
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  enable_extended_leave_statistics=>"true",
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther
                  ));
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);
                  if ((grep /^$thisIgmpServer/,@IpV6ServerHostNames) == 0) {
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_Igmp";
                  }
                  else {
                    $thisInterestedGroupList = "Iggl".$thisServerHostName."_Igmp".$v6suffix;
                  }

                  $Tg->NewTemplate();
                  $Tg->Add(diversifEye::IgmpClient->new(
                  name=>$Alias."_".$base_name,
                  description=>$thisIgmpDescription,
                  host=>$host_name,
                  start_after=>$thisStartAfter,
                  start_after_metric=>"ms",
                  stop_after=>$thisStopAfter,
                  stop_after_metric=>"secs",
                  media_transport=>$thisMediaTransport,
                  interested_group_selection=>'Specific Group',
                  interested_group_list=>$thisInterestedGroupList,
                  multicast_group_address=>$thisMulticastGroupAddrerss,
                  source_port=>$thisSourcePort,
                  destination_port=>$thisDestinationPort,
                  accept_from_any_src_port=>'false',
                  accept_to_any_dst_port=>'false',
                  is_normal_stats_enabled=>$NormalStatsEnabled,
                  is_fine_stats_enabled=>$FineStatsEnabled,
                  enable_extended_leave_statistics=>"true",
                  service_state=>$ServiceState,
                  administrative_state=>$AsOther
                  ));
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }



  #
  #   cPing Client
  #
  if ((defined $loadProfilesKey->{'cPing'}) && ($CpingEnabled eq 1) && ($VERSION >= 8.5)) {

    printf(STDERR "%s\n", 'Generating cPing Applications ...');
    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'cPing'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'cPing'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      $Alias = $defaultCpingAlias;
      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }

      $thisPingDescription = $defaultCpingDescription;  # The default description
      if (defined $thisKey->[$i]->{'Description'}) {
        $thisPingDescription = $thisKey->[$i]->{'Description'};
      }

      $thisPingTargetIp = $defaultPingTargetIp;
      if (defined $thisKey->[$i]->{'Ping_IP_Address'}) {
        if ($thisKey->[$i]->{'Ping_IP_Address'} ne "") {
          $thisPingTargetIp = $thisKey->[$i]->{'Ping_IP_Address'};
        }
      }

      $thisDelayBetweenPackets = $defaultPingInterval;
      if (defined $thisKey->[$i]->{'Delay_Between_Pings'}) {
        if (($thisKey->[$i]->{'Delay_Between_Pings'} ne "") && ($thisKey->[$i]->{'Delay_Between_Pings'} >= 1) && ($thisKey->[$i]->{'Delay_Between_Pings'} <= 3600000)) {
          $thisDelayBetweenPackets = $thisKey->[$i]->{'Delay_Between_Pings'};
        }
      }

      $thisPayloadSize = $defaultbPingPayloadSize;
      if (defined $thisKey->[$i]->{'Packet_Size'}) {
        if (($thisKey->[$i]->{'Packet_Size'} ne "") && ($thisKey->[$i]->{'Packet_Size'} >= 41) && ($thisKey->[$i]->{'Packet_Size'} <= 1464)) {
          $thisPayloadSize = $thisKey->[$i]->{'Packet_Size'};
        }
      }

      $thisStartAfter = $defaultPingStartAfter;
      if (defined $thisKey->[$i]->{'Start_After'}) {
        if (($thisKey->[$i]->{'Start_After'} ne "") && ($thisKey->[$i]->{'Start_After'} >= 1) && ($thisKey->[$i]->{'Start_After'} <= 3600000)) {
          $thisStartAfter = $thisKey->[$i]->{'Start_After'};
        }
      }

      $thisStopAfter = $defaultPingStopAfter;
      if (defined $thisKey->[$i]->{'Stop_After'}) {
        if (($thisKey->[$i]->{'Stop_After'} ne "") && ($thisKey->[$i]->{'Stop_After'} >= 1) && ($thisKey->[$i]->{'Stop_After'} <= 86400)) {
          $thisStopAfter = $thisKey->[$i]->{'Stop_After'};
        }
      }

      for $pdn (0..$PDNs_per_UE-1) {
        if ($Alias eq $defaultCpingAlias) {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias.$rangeStr."_".$profileName."_CPING_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@PingAliasNames) == 0) {
            push(@PingAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {

                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);

                  if (index($thisPingTargetIp, ":") == -1) {
                    $pppoeStr = "pppoe_";
                  }
                  else {
                    $pppoeStr = "pppoe6_";
                  }

                  if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                    ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                    $thisPppoeStartPos = $startingAt - $pppMinVal;
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$incrementSize));
                  }
                  else {
                    $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize));
                  }

                  $Tg->NewTemplate();
                  $Tg->Add(diversifEye::PingApp->new(scale_factor=>$scaleFactor,
                    name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
                    description=>$thisPingDescription,
                    host=>$thisHost,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    ping_ip_address=>$thisPingTargetIp,
                    delay_between_pings=>$thisDelayBetweenPackets,
                    delay_between_pings_metric=>"ms",
                    packet_size=>$thisPayloadSize,
                    service_state=>$ServiceState));
                }
              }
            }
            else {

              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }

                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  $isIPv6Host = 0;
                  if ($PPPoEIPv6Enabled eq 1) {
                    if (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange eq "")) {
                      $isIPv6Host = 1;
                    }
                    elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange ne "")) {
                      if ((isInRange($ue, $PPPoEIPv6UeRange) == 1) && (isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                    elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange eq "")) {
                      if ((isInRange($ue, $PPPoEIPv6UeRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                    elsif (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange ne "")) {
                      if ((isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                  }

                  if ( ($isIPv6Host eq 0) && (index($thisPingTargetIp, ":") == -1) ) {
                    $Tg->NewTemplate();
                    $Tg->Add(diversifEye::PingApp->
                    new(name=>$Alias."_".$base_name,
                    description=>$thisPingDescription,
                    host=>$host_name,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    ping_ip_address=>$thisPingTargetIp,
                    delay_between_pings=>$thisDelayBetweenPackets,
                    delay_between_pings_metric=>"ms",
                    packet_size=>$thisPayloadSize,
                    service_state=>$ServiceState));
                 }
                 elsif ( ($isIPv6Host eq 1) && (index($thisPingTargetIp, ":") != -1) ) {
                    $Tg->NewTemplate();
                    $Tg->Add(diversifEye::PingApp->
                    new(name=>$Alias."_".$base_name,
                    description=>$thisPingDescription,
                    host=>$host_name,
                    is_normal_stats_enabled=>$NormalStatsEnabled,
                    is_fine_stats_enabled=>$FineStatsEnabled,
                    start_after=>$thisStartAfter,
                    start_after_metric=>"ms",
                    stop_after=>$thisStopAfter,
                    stop_after_metric=>"secs",
                    aggregate_group=>$thisAggregateGroupName,
                    ping_ip_address=>$thisPingTargetIp,
                    delay_between_pings=>$thisDelayBetweenPackets,
                    delay_between_pings_metric=>"ms",
                    packet_size=>$thisPayloadSize,
                    service_state=>$ServiceState));
                 }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }


  #
  #   sPing Client
  #
  if ((defined $loadProfilesKey->{'sPing'}) && ($SpingEnabled eq 1) && ($VERSION >= 8.5)) {

    printf(STDERR "%s\n", 'Generating sPing Applications ...');

    $thisKey = ();
    $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'sPing'};
    $i = 0;

    if (!($thisKey =~ /ARRAY/)) {
      $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'sPing'}];
    }

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      $ServerHostName = "";
      if (defined $thisKey->[$i]->{'Server_Host_Name'}) {
        if ($thisKey->[$i]->{'Server_Host_Name'} ne "") {
          $ServerHostName = $thisKey->[$i]->{'Server_Host_Name'};
        }
      }

      $host_name = $ServerHostName;
      foreach $key (keys %serverHosts) {
        if ($key ne $ServerHostName) {
          if ($serverHosts{$key} eq $serverHosts{$ServerHostName}) {
            $host_name = "Host_".$serverHosts{$key};
            $host_name =~ s/:/-/g;
          }
        }
      }

      $Alias = $defaultSpingAlias;
      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }

      $thisPingDescription = $defaultSpingDescription;
      if (defined $thisKey->[$i]->{'Description'}) {
        $thisPingDescription = $thisKey->[$i]->{'Description'};
      }

      $thisPingTargetIp = $defaultPingTargetIp;
      if (defined $thisKey->[$i]->{'Ping_IP_Address'}) {
        if ($thisKey->[$i]->{'Ping_IP_Address'} ne "") {
          $thisPingTargetIp = $thisKey->[$i]->{'Ping_IP_Address'};
        }
      }

      $thisDelayBetweenPackets = $defaultPingInterval;
      if (defined $thisKey->[$i]->{'Delay_Between_Pings'}) {
        if (($thisKey->[$i]->{'Delay_Between_Pings'} ne "") && ($thisKey->[$i]->{'Delay_Between_Pings'} >= 1) && ($thisKey->[$i]->{'Delay_Between_Pings'} <= 3600000)) {
          $thisDelayBetweenPackets = $thisKey->[$i]->{'Delay_Between_Pings'};
        }
      }

      $thisPayloadSize = $defaultbPingPayloadSize;
      if (defined $thisKey->[$i]->{'Packet_Size'}) {
        if (($thisKey->[$i]->{'Packet_Size'} ne "") && ($thisKey->[$i]->{'Packet_Size'} >= 41) && ($thisKey->[$i]->{'Packet_Size'} <= 1464)) {
          $thisPayloadSize = $thisKey->[$i]->{'Packet_Size'};
        }
      }

      $thisStartAfter = $defaultPingStartAfter;
      if (defined $thisKey->[$i]->{'Start_After'}) {
        if (($thisKey->[$i]->{'Start_After'} ne "") && ($thisKey->[$i]->{'Start_After'} >= 1) && ($thisKey->[$i]->{'Start_After'} <= 3600000)) {
          $thisDelayBetweenPackets = $thisKey->[$i]->{'Start_After'};
        }
      }

      $thisStopAfter = $defaultPingStopAfter;
      if (defined $thisKey->[$i]->{'Stop_After'}) {
        if (($thisKey->[$i]->{'Stop_After'} ne "") && ($thisKey->[$i]->{'Stop_After'} >= 1) && ($thisKey->[$i]->{'Stop_After'} <= 86400)) {
          $thisDelayBetweenPackets = $thisKey->[$i]->{'Stop_After'};
        }
      }

      for $pdn (0..$PDNs_per_UE-1) {
        if ($Alias eq $defaultSpingAlias) {
          $AliasEntryName = $Alias."_".$ServerHostName."_".$rangeStr."_".$profileName."_PDN".$pdn;  # The default name
        }
        else {
          $AliasEntryName = $Alias."_".$ServerHostName."_".$rangeStr."_".$profileName."_SPING_PDN".$pdn;
        }

        # Check the Alias has not been used if it has ignore configuration
        if ((grep /^$AliasEntryName/,@PingAliasNames) == 0) {
            push(@PingAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {

                  $Tg->NewTemplate();
                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone, $pdn);
#                  $Tg->NewTemplate();
#                  $Tg->Add(diversifEye::PingApp->new(scale_factor=>$scaleFactor,
#                    name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$startingAt, increment_size=>$incrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName),
#                    description=>$thisPingDescription,
#                    host=>diversifEye::PsScaled->new(scaled_entity=>$host_name, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$startingAt, position_offset=>$incrementSize)),
#                    is_normal_stats_enabled=>$NormalStatsEnabled,
#                    is_fine_stats_enabled=>$FineStatsEnabled,
#                    start_after=>$thisStartAfter,
#                    start_after_metric=>"ms",
#                    stop_after=>$thisStopAfter,
#                    stop_after_metric=>"secs",
#                    aggregate_group=>$thisAggregateGroupName,
#                    ping_ip_address=>$thisPingTargetIp,
#                    delay_between_pings=>$thisDelayBetweenPackets,
#                    delay_between_pings_metric=>"ms",
#                    packet_size=>$thisPayloadSize,
#                    service_state=>$ServiceState));
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {
                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if ($createEntry)  {

                  $isIPv6Host = 0;
                  if ($PPPoEIPv6Enabled eq 1) {
                    if (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange eq "")) {
                      $isIPv6Host = 1;
                    }
                    elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange ne "")) {
                      if ((isInRange($ue, $PPPoEIPv6UeRange) == 1) && (isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                    elsif (($PPPoEIPv6UeRange ne "") && ($PPPoEIPv6PdnRange eq "")) {
                      if ((isInRange($ue, $PPPoEIPv6UeRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                    elsif (($PPPoEIPv6UeRange eq "") && ($PPPoEIPv6PdnRange ne "")) {
                      if ((isInRange($pdn, $PPPoEIPv6PdnRange) == 1)) {
                        $isIPv6Host = 1;
                      }
                    }
                  }

                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }

                  if ($doStatisticGroups) {
                    $thisAggregateGroupName = $Alias."_".$base_name;
                  }
                  else {
                    $thisAggregateGroupName = "";
                  }

                  if ( ($isIPv6Host eq 0) && (index($thisPingTargetIp, ":") == -1) ) {
                     $Tg->NewTemplate();
                     $Tg->Add(diversifEye::PingApp->
                     new(name=>$Alias."_".$ServerHostName."_".$base_name,
                     description=>$thisPingDescription,
                     host=>$host_name,
                     is_normal_stats_enabled=>$NormalStatsEnabled,
                     is_fine_stats_enabled=>$FineStatsEnabled,
                     start_after=>$thisStartAfter,
                     start_after_metric=>"ms",
                     stop_after=>$thisStopAfter,
                     stop_after_metric=>"secs",
                     aggregate_group=>$thisAggregateGroupName,
                     ping_ip_address=>$thisPingTargetIp,
                     delay_between_pings=>$thisDelayBetweenPackets,
                     delay_between_pings_metric=>"ms",
                     packet_size=>$thisPayloadSize,
                     service_state=>$ServiceState));
                  }
                  elsif ( ($isIPv6Host eq 1) && (index($thisPingTargetIp, ":") != -1) ) {
                     $Tg->NewTemplate();
                     $Tg->Add(diversifEye::PingApp->
                     new(name=>$Alias."_".$ServerHostName."_".$base_name,
                     description=>$thisPingDescription,
                     host=>$host_name,
                     is_normal_stats_enabled=>$NormalStatsEnabled,
                     is_fine_stats_enabled=>$FineStatsEnabled,
                     start_after=>$thisStartAfter,
                     start_after_metric=>"ms",
                     stop_after=>$thisStopAfter,
                     stop_after_metric=>"secs",
                     aggregate_group=>$thisAggregateGroupName,
                     ping_ip_address=>$thisPingTargetIp,
                     delay_between_pings=>$thisDelayBetweenPackets,
                     delay_between_pings_metric=>"ms",
                     packet_size=>$thisPayloadSize,
                     service_state=>$ServiceState));
                  }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }



  #
  #    VoIP Client - only one per PDN supported
  #
      if ( ( (defined $loadProfilesKey->{'VoIP'}) || (defined $loadProfilesKey->{'VoIMS'}) ) && ($VoipEnabled eq 1) ) {

    printf(STDERR "%s\n", 'Generating VoIP (and VoIMS) Applications...');

    $thisKey = ();
    $nextKeyId = 0;

    if (defined $loadProfilesKey->{'VoIP'}) {
      $thisKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'};
      if (!($thisKey =~ /ARRAY/)) {
        $thisKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIP'}];
      }
      foreach (@{$thisKey}) {
        $nextKeyId = $nextKeyId + 1;
      }
    }

    if (defined $loadProfilesKey->{'VoIMS'}) {
      $thisVoimsKey = ();
      $thisVoimsKey = $xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'};
      if (!($thisVoimsKey =~ /ARRAY/)) {
        $thisVoimsKey = [$xmlHash->{'diversifEye_Configuration'}->{'Application_Configuration'}->{'Client_Profiles'}->{$profileName}->{'VoIMS'}];
      }
      $i = 0;
      foreach (@{$thisVoimsKey}) {
        if (!defined $thisVoimsKey->[$i]->{'Description'}) {
          $thisVoimsKey->[$i]->{'Description'} = $defaultVoimsDescription;
        }
        $thisVoimsKey->[$i]->{'Alias'} = $defaultVoimsAlias;
        $thisKey->[$nextKeyId] = $thisVoimsKey->[$i];
        $i = $i + 1;
        $nextKeyId = $nextKeyId + 1;
      }
    }
    $i = 0;

    foreach (@{$thisKey}) {
      $UeRange = "";
      $PdnRange = "";
      if (defined $thisKey->[$i]->{'UE'}) {
        $UeRange = $thisKey->[$i]->{'UE'};
      }

      if (defined $thisKey->[$i]->{'PDN'}) {
        $PdnRange = $thisKey->[$i]->{'PDN'};
      }
      $rangeStr = cleanRange($UeRange, $PdnRange);

      if (defined $thisKey->[$i]->{'Alias'}) {
        $Alias = cleanAlias($thisKey->[$i]->{'Alias'});
      }
      else {
        $Alias = $defaultVoipAlias;
      }

      if (defined $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}) {

        $TcpCharacteristicsName = $TcpCharacteristicsDefault;
        if (defined $thisKey->[$i]->{'TCP_Characteristics'}) {
          if (  (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Window_Scale'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Use_SACK_When_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Set_SACK_Permitted'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Max_Advertised_Received_Window_Size'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Support_Timestamp_when_requested'}) ||
                (defined $thisKey->[$i]->{'TCP_Characteristics'}->{'Request_Timestamp'})   ) {
            if ($Alias eq $defaultVoipAlias) {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix;
            }
            else {
              $TcpCharacteristicsName = $Alias.$rangeStr.$suffix.$TcpCharVoIPId;
            }
          }
        }

        if (defined $thisKey->[$i]->{'Description'}) {
          $thisVoipDescription = $thisKey->[$i]->{'Description'};
        }
        else {
          $thisVoipDescription = $defaultVoipDescription;  # The default description
        }

        $thisLatencyStats = $LatencyStatsEnabled;
        if (defined $thisKey->[$i]->{'Latency_Statistics'}) {
          if (lc($thisKey->[$i]->{'Latency_Statistics'}) eq "true") {
            $thisLatencyStats = "true";
          }
          else {
            $thisLatencyStats = "false";
          }
        }

        $thisGenerateRtcpReports = "false";
        if (defined $thisKey->[$i]->{'Generate_Rtcp_Reports'}) {
          if (lc($thisKey->[$i]->{'Generate_Rtcp_Reports'}) eq "true") {
            $thisGenerateRtcpReports = "true";
          }
        }

        $thisSIPServer = $SIPServer;
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}) {
          $thisSIPServer = $thisKey->[$i]->{'SIP_Server'}->{'Server_Host_Name'}."_voip";
        }

        $thisSIPUsername = $SIPUsername;
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Username'}) {
          $thisSIPUsername = $thisKey->[$i]->{'SIP_Server'}->{'Username'};
        }

        $thisSIPPassword = $SIPPassword;
        $sip_usernameaspassword = "true";
        if (defined $thisKey->[$i]->{'SIP_Server'}{'Password'}) {
          $thisSIPPassword = $thisKey->[$i]->{'SIP_Server'}->{'Password'};
          $sip_usernameaspassword = "false";
        }

        $useSipAuthUsername = "false";
        $thisSipAuthUsername =  "";
        if (defined $thisKey->[$i]->{'SIP_Server'}{'SIP_Auth_Username'}) {
          $thisSipAuthUsername = $thisKey->[$i]->{'SIP_Server'}->{'SIP_Auth_Username'};
          $useSipAuthUsername = "true";
        }


        $thisSIPDomain = $SIPDomain;
        if (defined $thisKey->[$i]->{'SIP_Server'}{'Domain'}) {
          $thisSIPDomain = $thisKey->[$i]->{'SIP_Server'}->{'Domain'};
        }

        $thisSIPPort = $SIPTransportPort;
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Port'}) {
          if (($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Port'} > 0) && ($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Port'} <= 65536)) {
            $thisSIPPort = $thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Port'};
          }
        }

        $thisSIPType = $SIPTransportType;
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'}) {
          if (($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'} eq "UDP") || ($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'} eq "TCP")  || ($thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'} eq "TLS")) {
            $thisSIPType = $thisKey->[$i]->{'SIP_Server'}->{'SIP_Transport_Type'};
          }
        }

        if ($thisSIPType ne "TCP") {
          $TcpCharacteristicsName = "";
        }

        $thisSIPRegisterWithServer = "true";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Register_With_Server'}) {
          if (lc($thisKey->[$i]->{'SIP_Server'}->{'Register_With_Server'}) eq "false") {
            $thisSIPRegisterWithServer = "false";
          }
        }

        $thisSend100Trying = "false";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Send_100_Trying'}) {
          if (lc($thisKey->[$i]->{'SIP_Server'}->{'Send_100_Trying'}) eq "true") {
            $thisSend100Trying = "true";
          }
        }

        $thisUse100RelPrack = "false";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Use_100_Rel_Prack'}) {
          if (lc($thisKey->[$i]->{'SIP_Server'}->{'Use_100_Rel_Prack'}) eq "true") {
            $thisUse100RelPrack = "true";
          }
        }

        $thisSessionTimer = "";
        $thisSessionTimerEnable = "false";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Session_Timer'}) {
          if (($thisKey->[$i]->{'SIP_Server'}->{'Session_Timer'} > 0) && ($thisKey->[$i]->{'SIP_Server'}->{'Session_Timer'} <= 3600)) {
            $thisSessionTimer = $thisKey->[$i]->{'SIP_Server'}->{'Session_Timer'};
            $thisSessionTimerEnable = "true";
          }
        }

        $thisRegistrationInterval = "";
        $thisUseServerInterval = "true";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Registration_Interval'}) {
          if (($thisKey->[$i]->{'SIP_Server'}->{'Registration_Interval'} > 0) && ($thisKey->[$i]->{'SIP_Server'}->{'Registration_Interval'} <= 86400)) {
            $thisRegistrationInterval = $thisKey->[$i]->{'SIP_Server'}->{'Registration_Interval'};
            $thisUseServerInterval = "false";
          }
        }

        $thisClientIpAsDomain = "false";
        if (defined $thisKey->[$i]->{'SIP_Server'}->{'Client_IP_as_Domain'}) {
          if (lc($thisKey->[$i]->{'SIP_Server'}->{'Client_IP_as_Domain'}) eq "true") {
            $thisClientIpAsDomain = "true";
          }
        }

        $thisSIPAllowDelayBetweenCalls = "false";
        if (defined $thisKey->[$i]->{'Allow_Delay_Between_Calls'}) {
          if ($thisKey->[$i]->{'Allow_Delay_Between_Calls'} eq "true") {
            $thisSIPAllowDelayBetweenCalls = "true";
            if (defined $thisKey->[$i]->{'BHCA'}) {
              $thisSIPBHCA = $thisKey->[$i]->{'BHCA'};
            }
          }
        }

        $thisSIPAverageHoldTime = $SIPAverageHoldTime;
        if (defined $thisKey->[$i]->{'Call_Duration'}) {
          $thisSIPAverageHoldTime = $thisKey->[$i]->{'Call_Duration'};
        }

        $thisSIPDestinationCallURIType = $SIPDestinationCallURIType;
        if (defined $thisKey->[$i]->{'Destination_Call_URI_Is_SIP'}) {
          if ($thisKey->[$i]->{'Destination_Call_URI_Is_SIP'} eq "true") {
            $thisSIPDestinationCallURIType = "SIP";
          }
        }

        $sip_averageholdtime = $thisSIPAverageHoldTime;
        $sip_allowdelaybetweencalls = "false";
        $sip_bhca = "";
        if (($thisSIPAllowDelayBetweenCalls eq "true") && ($thisSIPBHCA > 0)) {
          $sip_bhca = $thisSIPBHCA;
          $sip_allowdelaybetweencalls = "true";
          if ((ceil($sip_averageholdtime/1000)+3) > (3600 * (1/$sip_bhca))) {
            $sip_averageholdtime = floor(((3600 * (1/$sip_bhca))-3) * 1000);
          }
        }

        $rtp_port_profile = $VoipPortProfileDefault;
        if (defined $thisKey->[$i]->{'Rtp_Port'}) {
          $thisMediaPorts = $thisKey->[$i]->{'Rtp_Port'};
          $thisMediaPorts =~ s/\.\./-/g;  # change .. to -
          if ($thisMediaPorts =~ m/\-/) {
            $rtp_port_profile = "Voip_".$thisMediaPorts;
          }
          else {
            $rtp_port_profile = $thisMediaPorts;
          }
        }

        $stream_profile = $Alias.$rangeStr.$suffix;

        $thisInitialCallDelay = 0;
        if (defined $thisKey->[$i]->{'Initial_Call_Delay'}) {
          if (($thisKey->[$i]->{'Initial_Call_Delay'} > 0) && ($thisKey->[$i]->{'Initial_Call_Delay'} <= 86400000)) {
            $thisInitialCallDelay = $thisKey->[$i]->{'Initial_Call_Delay'};
          }
        }

        $thisCallAnsweringDelay = 0;
        if (defined $thisKey->[$i]->{'Call_Answering_Delay'}) {
          if (($thisKey->[$i]->{'Call_Answering_Delay'} > 0) && ($thisKey->[$i]->{'Call_Answering_Delay'} <= 30000)) {
            $thisCallAnsweringDelay = $thisKey->[$i]->{'Call_Answering_Delay'};
          }
        }

        $thisConfigurePassiveAnalysis = "false";
        $thisPaEnablePassiveAnalysisStats = "true";
        $thisPaPlayoutJitter = "40";
        $thisPaMaxJitter = "80";
        $thisPaMediaType = "voice";
        $thisPaVideoCodec = "";
        $thisPaAnalyseMpeg2tsEs = "false";
        $thisPaAutoDeterminePid = "true";
        $thisPaVideoPid = "";
        $thisEnableAmrLevelChanging = 'false';
        $thisAmrLevelChangeInterval = 40;
        $thisLevelChangeList = "";

        if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}) {
          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Playout_Jitter'}) {
            if (($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Playout_Jitter'} >= 0) && ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Playout_Jitter'} <= 65535)) {
              $thisPaPlayoutJitter = $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Playout_Jitter'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Max_Jitter'}) {
            if (($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Max_Jitter'} >= 0) && ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Max_Jitter'} <= 65535)) {
              $thisPaMaxJitter = $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Max_Jitter'};
              $thisConfigurePassiveAnalysis = "true";
            }
          }

          if ($thisPaPlayoutJitter > $thisPaMaxJitter) {
            $thisPaMaxJitter = $thisPaPlayoutJitter;
          }


          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Media_Type'}) {
            if ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Media_Type'} eq 'Multimedia') {
              $thisPaMediaType = 'video';
              $thisConfigurePassiveAnalysis = 'true';
            }
          }

          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Codec'}) {
            if (grep /$thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Codec'}/, @diversifEyePaVoipVideoCodecs) {
              $thisPaVideoCodec = $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Codec'};
              $thisConfigurePassiveAnalysis = 'true';
            }
          }

          # There is a problem with the static causeing an exception with the Analyse_MPEG2TS_ES flag set to either True or False (should be false).
          if ($thisPaVideoCodec eq "Static") {
            $thisPaVideoCodec = "";
          }

          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Analyse_MPEG2TS_ES'}) {
            if (($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Analyse_MPEG2TS_ES'} eq 'true') && ($thisPaVideoCodec ne "Static")){
              $thisPaAnalyseMpeg2tsEs = 'true';
              $thisConfigurePassiveAnalysis = 'true';
            }
          }

          if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Pid'}) {
            if (($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Pid'} >= 16) && ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Pid'} <= 8192)) {
              $thisPaVideoPid = $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Video_Pid'};
            }
          }

          if ($thisPaVideoCodec eq "") {
            $thisPaVideoPid = "";
            $thisPaAnalyseMpeg2tsEs = "false";
            $thisPaMediaType = "voice";
          }

          if ($thisPaVideoPid eq "") {
            $thisPaAutoDeterminePid = "true";
          }
          else {
            $thisPaAutoDeterminePid = "false";
            $thisConfigurePassiveAnalysis = "true";
          }
        }

        if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}) {
          if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_Interval'}) {
            if (($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_Interval'} > 0) && ($thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_Interval'} <= 3600000)) {
              $thisAmrLevelChangeInterval = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_Interval'};
            }
          }

          $thisLevelChangeList = "";
          if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}) {

            if (defined $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'}) {
              $changesKey = $thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'};
              $j = 0;

              if (!($changesKey =~ /ARRAY/)) {
                $changesKey = [$thisKey->[$i]->{'VoIP_Media_Profile'}->{'Adaptive_AMR_List'}->{'Change_List'}->{'Change_Entry'}];
              }

              if (scalar @{$changesKey} >= 1) {
                foreach (@{$changesKey}) {
                  if (($changesKey->[$j] > 0) && ($changesKey->[$j] < 99)) {
                    if ($thisLevelChangeList eq "") {
                      $thisLevelChangeList = $Alias.$rangeStr.$suffix;
                    }
                  }
                  $j = $j + 1;
                }
              }
            }
          }

          if ($thisLevelChangeList ne "") {
            $thisEnableAmrLevelChanging = 'true';
          }
        }

        # Defaults for normal VoIP.
        $thisVoLteAuthAlgorithm = "Digest";
        $thisVoLteAkaKey = "";
        $thisVoLteAkaKeyUeId = 0;
        $thisVoLteAkaOperatorId = "00000000000000000000000000000000";
        $thisVoLteProtectedSipPort = "2468";
        $thisVoLteEspEncAlgorithm = "aes-cbc";
        $thisVoLteEspAuthAlgorithm = "hmac-md5-96";

        # Defaults for no SMS (V.11+)
        $thisThreeGppImsMultimediaTelephonySupport = "false";
        $thisThreeGppSmsSupport = "None";
        $thisSmsGateway = "";
        $thisSmsRecipient = "";
        $thisMessageList = "";
        $thisNumberOfSmsInABurst = "2";
        $thisDelayBetweenSms = "60";
        $thisDelayBetweenBursts = "1";
        $thisInitialSmsDelay = "0";

        # Get VoLTE options if set.
        if (defined $thisKey->[$i]->{'VoLTE'}->{'AKA_Key'}) {
          if ($thisKey->[$i]->{'VoLTE'}->{'AKA_Key'} ne "") {

            if (index($thisKey->[$i]->{'VoLTE'}->{'AKA_Key'}, "+%UE_ID%") != -1) {
              ($thisTempAkaKey, $strSuffix) = split(/\+%UE_ID%/, $thisKey->[$i]->{'VoLTE'}->{'AKA_Key'}, 2);
              if ( length($thisTempAkaKey) > 32) {
                $thisTempAkaKey = substr( $thisTempAkaKey, 0, 32 );
                $thisVoLteAkaKeyUeId = 1;
              }
            }
            else {
              $thisTempAkaKey = $thisKey->[$i]->{'VoLTE'}->{'AKA_Key'};
              if ( length($thisTempAkaKey) > 32) {
                $thisTempAkaKey = substr( $thisTempAkaKey, 0, 32 );
              }
            }

            if ( $thisTempAkaKey =~ /^[0-9a-fA-F]+$/ ) {

              if ($useScaledEntities eq 1) {
                $thisVoLteAkaKey = diversifEye::PsHex->new( start=>$thisTempAkaKey, increment_size=>"1");
              }
              else {
                $thisTempAkaKey = "0x".$thisTempAkaKey;
                $thisVoLteAkaKey = Math::BigInt->new($thisTempAkaKey);
              }

              # Only continue if we have a key.
              $thisVoLteAuthAlgorithm = "VoLTE-AKA-ESP";
              if (defined $thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'}) {
                if ($thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'} ne "") {
                  if ( $thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'} =~ /[0-9a-fA-F]+/ ) {
                    if ( length($thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'}) > 32) {
                      $thisVoLteAkaOperatorId = substr( $thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'}, 0, 32 );;
                    }
                    else {
                      $thisVoLteAkaOperatorId = $thisKey->[$i]->{'VoLTE'}->{'AKA_Operator_Id'};
                    }
                  }
                }
              }

              if (defined $thisKey->[$i]->{'VoLTE'}->{'Protected_SIP_Port'}) {
                if ($thisKey->[$i]->{'VoLTE'}->{'Protected_SIP_Port'} ne "") {
                  if (($thisKey->[$i]->{'VoLTE'}->{'Protected_SIP_Port'} >= 1) && ($thisKey->[$i]->{'VoLTE'}->{'Protected_SIP_Port'} <= 65535)) {
                    $thisVoLteProtectedSipPort = $thisKey->[$i]->{'VoLTE'}->{'Protected_SIP_Port'};
                  }
                }
              }

              if (defined $thisKey->[$i]->{'VoLTE'}->{'ESP_Encryption_Algorithm'}) {
                if (($thisKey->[$i]->{'VoLTE'}->{'ESP_Encryption_Algorithm'} eq "aes-cbc") || ($thisKey->[$i]->{'VoLTE'}->{'ESP_Encryption_Algorithm'} eq "des-ede3-cbc")) {
                  $thisVoLteEspEncAlgorithm = $thisKey->[$i]->{'VoLTE'}->{'ESP_Encryption_Algorithm'};
                }
              }

              if (defined $thisKey->[$i]->{'VoLTE'}->{'ESP_Auth_Algorithm'}) {
                if (($thisKey->[$i]->{'VoLTE'}->{'ESP_Auth_Algorithm'} eq "hmac-md5-96") || ($thisKey->[$i]->{'VoLTE'}->{'ESP_Auth_Algorithm'} eq "hmac-sha1-96")) {
                  $thisVoLteEspAuthAlgorithm = $thisKey->[$i]->{'VoLTE'}->{'ESP_Auth_Algorithm'};
                }
              }

              if (defined $thisKey->[$i]->{'VoLTE'}->{'Three_GPP_IMS_Multimedia'}) {
                if (lc($thisKey->[$i]->{'VoLTE'}->{'Three_GPP_IMS_Multimedia'}) eq "true") {
                  $thisThreeGppImsMultimediaTelephonySupport = "true";
                }
              }

              if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}) {
                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Gateway'}) {
                  $thisSmsGateway = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Gateway'};
                  if ($thisSmsGateway !~ /\D/) {
                    # Is numbers only
                    $thisSmsGateway = "tel:".$thisSmsGateway;
                  }
                  else {
                    $thisSmsGateway = "sip:".$thisSmsGateway;
                  }
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Recipient'}) {
                  $thisSmsRecipient = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Recipient'};
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'SMS_Message'}) {
                  $thisMessageList = $Alias.$SmsListId."_".$profileName."_".$rangeStr;
                }

                if (($thisSmsGateway ne "") && ($thisSmsGateway ne "") && ($thisMessageList ne "")) {
                  $thisThreeGppImsMultimediaTelephonySupport = "true";
                  $thisThreeGppSmsSupport = "Send/Receive SMS";
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Number_of_SMS_in_a_Burst'}) {
                  if (($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Number_of_SMS_in_a_Burst'} ne "") && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Number_of_SMS_in_a_Burst'} > 0) && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Number_of_SMS_in_a_Burst'} < 65535)) {
                    $thisNumberOfSmsInABurst = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Number_of_SMS_in_a_Burst'};
                  }
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_each_SMS'}) {
                  if (($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_each_SMS'} ne "") && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_each_SMS'} > 0) && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_each_SMS'} < 65535)) {
                    $thisDelayBetweenSms = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_each_SMS'};
                  }
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_Bursts'}) {
                  if (($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_Bursts'} ne "") && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_Bursts'} > 0) && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_Bursts'} < 65535)) {
                    $thisDelayBetweenBursts = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Delay_between_Bursts'};
                  }
                }

                if (defined $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Initial_SMS_Delay'}) {
                  if (($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Initial_SMS_Delay'} ne "") && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Initial_SMS_Delay'} > 0) && ($thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Initial_SMS_Delay'} < 65535)) {
                    $thisInitialSmsDelay = $thisKey->[$i]->{'VoLTE'}->{'SMS'}->{'Initial_SMS_Delay'};
                  }
                }

              }
            }
          }
        }

        for $pdn (0..$PDNs_per_UE-1) {

          $ipVersionEntryStr = "";
          if (((grep /^$thisSIPServer/,@IpV6ServerHostNames) != 0) && ($useScaledEntities eq 1)) {
            $ipVersionEntryStr = "_IPv6";
          }

          if ($Alias eq $defaultVoipAlias) {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_PDN".$pdn.$ipVersionEntryStr;  # The default name
          }
          else {
            $AliasEntryName = $Alias.$rangeStr."_".$profileName."_VoIP_PDN".$pdn.$ipVersionEntryStr;
          }

          # Check the Alias has not been used if it has ignore configuration
          if ((grep /^$AliasEntryName/,@VoipAliasNames) == 0) {
            push(@VoipAliasNames, $AliasEntryName);

            if ($useScaledEntities eq 1) {

              $createPdnEntry = 0;
              if ($PdnRange eq "") {
                $createPdnEntry = 1;
              }
              elsif ($PdnRange ne "") {
                if ((isInRange($pdn, $PdnRange) == 1)) {
                  $createPdnEntry = 1;
                }
              }

              if ($createPdnEntry eq 1) {
                if ($UeRange eq "") {
                  $UeRange = "0..".($conf{UEs}-1);
                }

                @UeGroups = ();
                if (index($UeRange, ",") != -1) {
                  @UeGroups = split(",", $UeRange);
                }
                else {
                  push(@UeGroups, $UeRange);
                }

                if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                  @pppoeGroups = ();
                  if (index($pppoeGroupList[$pdn], ",") != -1) {
                    @pppoeGroups = split(",", $pppoeGroupList[$pdn]);
                  }
                  else {
                    push(@pppoeGroups, $pppoeGroupList[$pdn]);
                  }

                  @NewUeGroups = ();
                  @PPPoEHostsForSplitGroups = {};
                  foreach  $thisUeRange (@UeGroups) {
                    $thisUeRange =~ s/-/\.\./g;
                    if ($thisUeRange =~ m/\.\./) {
                      ($ueMinVal, $ueMaxVal) = split('\.\.', $thisUeRange);
                      if ($ueMaxVal eq "") { # for the case "x.."
                        $ueMaxVal = $conf{UEs};
                      }
                    }
                    else {
                       $ueMinVal = $thisUeRange;
                       $ueMaxVal = $thisUeRange;
                    }

                    # We need to align the ranges with the unerlying PPPoE Hosts
                    @sortedPppoeGroups = sort(@pppoeGroups);
                    foreach  $thisPPPoERange (@sortedPppoeGroups) {
                      if ($thisPPPoERange =~ m/\.\./) {
                        ($pppMinVal, $pppMaxVal) = split('\.\.', $thisPPPoERange);
                        if ($pppMaxVal eq "") { # for the case "x.."
                          $pppMaxVal = $conf{UEs};
                        }
                      }
                      else {
                         $pppMinVal = $thisPPPoERange;
                         $pppMaxVal = $thisPPPoERange;
                      }
                      if (isInRange($ueMinVal, $thisPPPoERange) == 1) {
                        if (isInRange($ueMaxVal, $thisPPPoERange) == 1) {
                          if ($ueMinVal == $ueMaxVal) {
                            push(@NewUeGroups, $ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$ueMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$ueMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                        }
                        else {
                          if ($ueMinVal == $pppMaxVal) {
                            push(@NewUeGroups, $pppMaxVal);
                            $PPPoEHostsForSplitGroups{$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          else {
                            push(@NewUeGroups, $ueMinVal."..".$pppMaxVal);
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} = $thisPPPoERange;
                            $PPPoEHostsForSplitGroups{$ueMinVal."..".$pppMaxVal} =~ s/\.\./-/g;  # change .. to -
                          }
                          $ueMinVal = $pppMaxVal + 1;
                        }
                      }
                    }
                  }
                  @UeGroups = @NewUeGroups;
                }

                $oddOrEvenOrNone = "all";
                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if (($thisKey->[$i]->{'UE_Pattern'} eq "Even") || ($thisKey->[$i]->{'UE_Pattern'} eq "Odd")) {
                    $oddOrEvenOrNone = $thisKey->[$i]->{'UE_Pattern'};
                  }
                }

                if ($profileId != -1) {
                  $Alias = $Alias."_lp".sprintf("%01d", $profileId);
                }

                foreach $thisUeRange (@UeGroups) {

                  ($startingAt, $incrementSize, $scaleFactor, $overrideName) = getScaledItems($thisUeRange, $oddOrEvenOrNone);
                  $MtEnabled = 1;
                  $MoEnabled = 0;
                  $MtLabel = "";
                  $MoLabel = "";

                  if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                    if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                      $MtEnabled = 0;
                      $MoEnabled = 1;
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                      $MtEnabled = 1;
                      $MoEnabled = 1;
                      $MtLabel = "_even_mt";
                      $MoLabel = "_odd_mo";
                      $scaleFactor = floor($scaleFactor/2);
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                      $MtEnabled = 1;
                      $MoEnabled = 1;
                      $MtLabel = "_odd_mt";
                      $MoLabel = "_even_mo";
                      $scaleFactor = floor($scaleFactor/2);
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "None") {
                      $MtEnabled = 1;
                      $MoEnabled = 0;
                    }
                  }


                  $allowUaInitiateCalls = "false";
                  $thisCallListName = "";

                  $thisSIPServerName = $thisSIPServer;
                  if (($SIPTransportPort != $thisSIPPort) && ($doPerPortVoIPProxy eq 1)) {
                    $thisSIPServerName = $thisSIPServer."_".$thisSIPPort;
                  }

                  if ((grep /^$thisSIPServerName/,@InternalVoIPServerNames) != 0) {  # If we are to connect to a diversifEye internal server
                    $thisSIPRegisterWithServer = "false"
                  }

                  $thisUeConfigurePassiveAnalysis = $thisConfigurePassiveAnalysis;

                  # MO
                  if ($MoEnabled eq 1) {

                    $thisIncrementSize = $incrementSize;
                    $thisStartingAt = $startingAt;

                    if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                      if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                        $thisIncrementSize = 2;
                        if ($startingAt % 2 == 0) {
                          $thisStartingAt = $startingAt + 1;
                        }
                      }
                      elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                        $thisIncrementSize = 2;
                        if ($startingAt % 2) {
                          $thisStartingAt = $startingAt + 1;
                        }

                      }
                      elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                        $thisIncrementSize = 1;

                      }
                    }

                    $thisMoSIPUsername = $thisSIPUsername;
                    $thisMoSIPUsername =~ s/%DOMAIN%/$thisMoSIPUsername/g;
                    $thisCallUri = $thisMoSIPUsername;
                    if (index($thisMoSIPUsername, "+%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMoSIPUsername, 2);
                      if (($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") or ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even")) {
                        if ($thisSIPDestinationCallURIType eq "SIP") {
                          @callList = ();

                          for ($ue = $thisStartingAt; $ue < ($thisIncrementSize * $scaleFactor) + $startingAt; $ue += $thisIncrementSize) {
                            if ($strPrefix !~ /\D/) {
                              # Is numbers only
                              $thisUeMoSIPUsername = ($strPrefix+$ue)+1;
                            }
                            else {
                              # Contains a prefix.
                              @numberParts = split(/\D+/, $strPrefix);
                              $numberPart = $numberParts[-1];
                              $position = rindex($strPrefix, $numberPart);
                              $prefix = substr($strPrefix, 0, $position);
                              $thisUeMoSIPUsername = $prefix.(($numberPart+$ue)+1);
                            }
                            $thisUeMoSIPUsername =~ s/%UE_ID%/$ueStr/g;
                            $thisUeMoSIPUsername =~ s/%DOMAIN%/$thisSIPDomain/g;
                            if ($thisUeMoSIPUsername !~ /@/) {
                              $thisUeMoSIPUsername .= "@".$thisSIPDomain;
                            }
                            push(@callList, "sip:".$thisUeMoSIPUsername);
                          }
                          undef $thisCallUri;
                          $thisCallUri = diversifEye::PsStrl->new(values=>join(",",@callList));
                        }
                        else {
                          $thisCallUri = diversifEye::PsPhone->new(start=>$strPrefix+$thisStartingAt+1, increment_size=>$thisIncrementSize)
                        }
                      }
                      elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                        $thisCallUri = "1234567890";
                      }
                      $strPrefixPlus = "";
                      if (index($strPrefix, "+") == 0) {
                          $strPrefixPlus = "+"
                      }
                      $thisMoSIPUsername = diversifEye::PsPhone->new(start=>$strPrefixPlus.($strPrefix+($thisStartingAt * 1.0)), increment_size=>$thisIncrementSize)
                    }
                    elsif (index($thisMoSIPUsername, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMoSIPUsername, 2);
                      if (($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") or ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even")) {
                        if ($thisSIPDestinationCallURIType eq "SIP") {
                          @callList = ();
                          for ($ue = $thisStartingAt; $ue < ($thisIncrementSize*$scaleFactor) + $thisStartingAt; $ue += $thisIncrementSize) {
                              $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                              $thisUeMoSIPUsername = $thisMoSIPUsername;
                              $thisUeMoSIPUsername =~ s/%UE_ID%/$ueStr/g;
                              $thisUeMoSIPUsername =~ s/%DOMAIN%/$thisSIPDomain/g;
                              if ($thisUeMoSIPUsername !~ /@/) {
                                $thisUeMoSIPUsername .= "@".$thisSIPDomain;
                              }
                              push(@callList, $thisUeMoSIPUsername);
                          }
                          undef $thisCallUri;
                          $thisCallUri = diversifEye::PsStrl->new(values=>join(",",@callList));
                        }
                        else {
                          $thisCallUri = diversifEye::PsPhone->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt+1, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_calluri_".$overrideName);
                        }
                      }
                      elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                        $thisCallUri = "1234567890";
                      }
                      $thisMoSIPUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sipuser_".$overrideName);
                    }

                    $thisMoSIPAuthUsername = "";
                    if ($useSipAuthUsername eq "true") {
                      $thisMoSIPAuthUsername = $thisSipAuthUsername;
                      $thisMoSIPAuthUsername =~ s/%DOMAIN%/$thisMoSIPAuthUsername/g;
                      if (index($thisMoSIPAuthUsername, "+%UE_ID%") != -1) {
                        ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMoSIPAuthUsername, 2);
                        $strPrefixPlus = "";
                        if (index($strPrefix, "+") == 0) {
                            $strPrefixPlus = "+"
                        }
                        $thisMoSIPAuthUsername = diversifEye::PsPhone->new(start=>$strPrefixPlus.($strPrefix+($thisStartingAt * 1.0)), increment_size=>$thisIncrementSize)
                      }
                      elsif (index($thisMoSIPUsername, "%UE_ID%") != -1) {
                        ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMoSIPAuthUsername, 2);
                        $thisMoSIPAuthUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sipuser_".$overrideName);
                      }
                    }

                    $thisMoSIPPassword = $thisSIPPassword;
                    $thisMoSIPPassword =~ s/%DOMAIN%/$thisMoSIPPassword/g;
                    if (index($thisMoSIPPassword, "+%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMoSIPPassword, 2);
                      $thisMoSIPPassword = diversifEye::PsPhone->new(start=>$strPrefix+($thisStartingAt * 1.0), increment_size=>$thisIncrementSize)
                    }
                    elsif (index($thisMoSIPPassword, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMoSIPPassword, 2);
                      $thisMoSIPPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sippass_".$overrideName);
                    }

                    if ((grep /^$thisSIPServer/,@IpV6ServerHostNames) == 0) {
                      $pppoeStr = "pppoe_";
                    }
                    else {
                      $pppoeStr = "pppoe6_";
                    }

                    if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                      ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                      $thisPppoeStartPos = $startingAt - $pppMinVal;
                      if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                        if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                          if ($thisPppoeStartPos % 2 == 0) {
                            $thisPppoeStartPos = $thisPppoeStartPos + 1;
                          }
                        }
                        elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                          if ($thisPppoeStartPos % 2) {
                            $thisPppoeStartPos = $thisPppoeStartPos + 1;
                          }
                        }
                      }
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$thisIncrementSize));
                    }
                    else {
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisStartingAt, position_offset=>$thisIncrementSize));
                    }

                    $Tg->NewTemplate();
                    if ($VERSION >= 11) {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MoLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        three_gpp_ims_multimedia_telephony_support=>$thisThreeGppImsMultimediaTelephonySupport,
                        three_gpp_sms_support=>$thisThreeGppSmsSupport,
                        sms_gateway_uri=>$thisSmsGateway,
                        message_recipient_selection=>"E.164 Number",
                        e164_number=>$thisSmsRecipient,
                        sms_message_list=>$thisMessageList,
                        enable_sms_burst=>"true",
                        inter_sms_delay=>$thisDelayBetweenSms,
                        inter_sms_delay_metric=>"ms",
                        sms_burst_count=>$thisNumberOfSmsInABurst,
                        inter_sms_burst_delay=>$thisDelayBetweenSms,
                        inter_sms_burst_delay_metric=>"ms",
                        sms_burst_delay=>$thisDelayBetweenBursts,
                        sms_burst_delay_metric=>"ms",
                        initial_sms_delay=>$thisInitialSmsDelay,
                        initial_sms_delay_metric=>"ms",
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMoSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMoSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMoSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"Call URI",
                        call_uri=>$thisCallUri,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"true",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        use_server_interval=>$thisUseServerInterval,
                        registration_interval=>$thisRegistrationInterval,
                        registration_interval_metric=>'secs',
                        use_client_ip_as_sip_domainname=>$thisClientIpAsDomain,
                        enable_send_100_trying=>$thisSend100Trying,
                        support_100_rel_prack=>$thisUse100RelPrack,
                        enable_session_timer=>$thisSessionTimerEnable,
                        session_timer=>$thisSessionTimer,
                        session_timer_metric=>'secs',
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        generate_rtcp_reports=>$thisGenerateRtcpReports,
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                    elsif ($VERSION >= 10.4) {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MoLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMoSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMoSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMoSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"Call URI",
                        call_uri=>$thisCallUri,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"true",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                    else {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MoLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMoSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMoSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMoSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"Call URI",
                        call_uri=>$thisCallUri,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"true",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                  }

                  if ($MtEnabled eq 1) {
                    # MT
                    $thisIncrementSize = $incrementSize;
                    $thisStartingAt = $startingAt;
                    if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                      if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                        $thisIncrementSize = 2;
                        if ($startingAt % 2) {
                          $thisStartingAt = $startingAt + 1;
                        }
                      }
                      elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                        $thisIncrementSize = 2;
                        if ($startingAt % 2 == 0) {
                          $thisStartingAt = $startingAt + 1;
                        }
                      }
                    }

                    $thisMtSIPUsername = $thisSIPUsername;
                    $thisMtSIPUsername =~ s/%DOMAIN%/$thisMtSIPUsername/g;
                    if (index($thisMtSIPUsername, "+%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMtSIPUsername, 2);
                      $strPrefixPlus = "";
                      if (index($strPrefix, "+") == 0) {
                          $strPrefixPlus = "+"
                      }
                      $thisMtSIPUsername = diversifEye::PsPhone->new(start=>$strPrefixPlus.($strPrefix+($thisStartingAt * 1.0)), increment_size=>$thisIncrementSize)
                    }
                    elsif (index($thisMtSIPUsername, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMtSIPUsername, 2);
                      $thisMtSIPUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sipuser_".$overrideName);
                    }

                    $thisMtSIPAuthUsername = "";
                    if ($useSipAuthUsername eq "true")
                    {
                      $thisMtSIPAuthUsername = $thisSipAuthUsername;
                      $thisMtSIPAuthUsername =~ s/%DOMAIN%/$thisMtSIPAuthUsername/g;
                      if (index($thisMtSIPAuthUsername, "+%UE_ID%") != -1) {
                        ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMtSIPAuthUsername, 2);
                        $strPrefixPlus = "";
                        if (index($strPrefix, "+") == 0) {
                            $strPrefixPlus = "+"
                        }
                        $thisMtSIPAuthUsername = diversifEye::PsPhone->new(start=>$strPrefixPlus.($strPrefix+($thisStartingAt * 1.0)), increment_size=>$thisIncrementSize)
                      }
                      elsif (index($thisMtSIPUsername, "%UE_ID%") != -1) {
                        ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMtSIPAuthUsername, 2);
                        $thisMtSIPAuthUsername = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sipuser_".$overrideName);
                      }
                    }

                    $thisMtSIPPassword = $thisSIPPassword;
                    $thisMtSIPPassword =~ s/%DOMAIN%/$thisMtSIPPassword/g;
                    if (index($thisMtSIPPassword, "+%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split(/\+%UE_ID%/, $thisMtSIPPassword, 2);
                      $thisMtSIPPassword = diversifEye::PsPhone->new(start=>$strPrefix+($thisStartingAt * 1.0), increment_size=>$thisIncrementSize)
                    }
                    elsif (index($thisMtSIPPassword, "%UE_ID%") != -1) {
                      ($strPrefix, $strSuffix) = split("%UE_ID%", $thisMtSIPPassword, 2);
                      $thisMtSIPPassword = diversifEye::PsAlnum->new(prefix_label=>$strPrefix, suffix_label=>$strSuffix, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, value_override=>$strPrefix."_".$strSuffix."_sippass_".$overrideName);
                    }

                    if ((grep /^$thisSIPServer/,@IpV6ServerHostNames) == 0) {
                      $pppoeStr = "pppoe_";
                    }
                    else {
                      $pppoeStr = "pppoe6_";
                    }

                    if (($DiversifEyeType eq "1000") || ($DiversifEyeType eq "TeraVM")) {
                      ($pppMinVal, $pppMaxVal) = split('-', $PPPoEHostsForSplitGroups{$thisUeRange});
                      $thisPppoeStartPos = $startingAt - $pppMinVal;
                      if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                        if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                          if ($thisPppoeStartPos % 2 == 0) {
                            $thisPppoeStartPos = $thisPppoeStartPos + 1;
                          }
                        }
                        elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                          if ($thisPppoeStartPos % 2) {
                            $thisPppoeStartPos = $thisPppoeStartPos + 1;
                          }
                        }
                      }
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$PPPoEHostsForSplitGroups{$thisUeRange}."_pdn".$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisPppoeStartPos, position_offset=>$thisIncrementSize));
                    }
                    else {
                      $thisHost = diversifEye::PsScaled->new(scaled_entity=>$pppoeStr.$pdn, dist=>diversifEye::DeterminateDistribution->new(starting_position=>$thisStartingAt, position_offset=>$thisIncrementSize));
                    }

                    $Tg->NewTemplate();
                    if ($VERSION >= 11) {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MtLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        three_gpp_ims_multimedia_telephony_support=>$thisThreeGppImsMultimediaTelephonySupport,
                        three_gpp_sms_support=>$thisThreeGppSmsSupport,
                        sms_gateway_uri=>$thisSmsGateway,
                        message_recipient_selection=>"E.164 Number",
                        e164_number=>$thisSmsRecipient,
                        sms_message_list=>$thisMessageList,
                        enable_sms_burst=>"true",
                        inter_sms_delay=>$thisDelayBetweenSms,
                        inter_sms_delay_metric=>"ms",
                        sms_burst_count=>$thisNumberOfSmsInABurst,
                        inter_sms_burst_delay=>$thisDelayBetweenSms,
                        inter_sms_burst_delay_metric=>"ms",
                        sms_burst_delay=>$thisDelayBetweenBursts,
                        sms_burst_delay_metric=>"ms",
                        initial_sms_delay=>$thisInitialSmsDelay,
                        initial_sms_delay_metric=>"ms",
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMtSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMtSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMtSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"false",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        use_server_interval=>$thisUseServerInterval,
                        registration_interval=>$thisRegistrationInterval,
                        registration_interval_metric=>'secs',
                        use_client_ip_as_sip_domainname=>$thisClientIpAsDomain,
                        enable_send_100_trying=>$thisSend100Trying,
                        support_100_rel_prack=>$thisUse100RelPrack,
                        enable_session_timer=>$thisSessionTimerEnable,
                        session_timer=>$thisSessionTimer,
                        session_timer_metric=>'secs',
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        generate_rtcp_reports=>$thisGenerateRtcpReports,
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                    elsif ($VERSION >= 10.4) {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MtLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMtSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMtSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMtSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"false",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                    else {
                      $Tg->Add(diversifEye::VoipUa->new(scale_factor=>$scaleFactor,
                        name=>diversifEye::PsAlnum->new(prefix_label=>$Alias."_", suffix_label=>"_".$pdn, starting_at=>$thisStartingAt, increment_size=>$thisIncrementSize, padding_enabled=>$useScaledPadding, value_override=>$Alias."_".$overrideName.$MtLabel."_pdn".$pdn),
                        description=>$thisVoipDescription,
                        host=>$thisHost,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$thisMtSIPUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$thisMtSIPPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$thisMtSIPAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>"false",
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                    }
                  }
                }
              }
            }
            else {
              for $ue (0..$conf{UEs}-1) {

                $createEntry = 0;
                if (($UeRange eq "") && ($PdnRange eq "")) {
                  $createEntry = 1;
                }
                elsif (($UeRange ne "") && ($PdnRange ne "")) {
                  if ((isInRange($ue, $UeRange) == 1) && (isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange ne "") && ($PdnRange eq "")) {
                  if ((isInRange($ue, $UeRange) == 1)) {
                    $createEntry = 1;
                  }
                }
                elsif (($UeRange eq "") && ($PdnRange ne "")) {
                  if ((isInRange($pdn, $PdnRange) == 1)) {
                    $createEntry = 1;
                  }
                }

                if (defined $thisKey->[$i]->{'UE_Pattern'}) {
                  if ($thisKey->[$i]->{'UE_Pattern'} eq "Even") {
                    if ($ue % 2) {  # If the UE is odd then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                  elsif ($thisKey->[$i]->{'UE_Pattern'} eq "Odd") {
                    if ($ue % 2 == 0) { # If the UE is even then clear the create flag.
                      $createEntry = 0;
                    }
                  }
                }

                if ($createEntry)  {
                  $ueStr = sprintf("%0${MinimumUeIdDigits}s", $ue);
                  if ($profileId == -1) {
                    $base_name = $ueStr."_".sprintf("%s", $pdn);
                  }
                  else {
                    $base_name = "lp".sprintf("%01d", $profileId)."_".$ueStr."_".sprintf("%s", $pdn);
                  }
                  $host_name = "pppoe_".$ueStr."_".sprintf("%s", $pdn);

                  $sipUsername = $thisSIPUsername;
                  # Check for the numerical addition of UE_ID in the username or substitution
                  $position = rindex($sipUsername, "+%UE_ID%");
                  if ($position != -1) {
                    $numPart = substr($sipUsername, 0, $position);
                    if ($numPart !~ /\D/) {
                      # Is numbers only
                      $sipUsername = ($numPart+$ue);
                    }
                    else {
                      # contains a prefix.
                      @numberParts = split(/\D+/, $numPart);
                      $numberPart = $numberParts[-1];
                      $position = rindex($numPart, $numberPart);
                      $prefix = substr($numPart, 0, $position);
                      $sipUsername = $prefix.($numberPart+$ue);
                    }
                  }

                  $sipUsername =~ s/%UE_ID%/$ueStr/g;
                  $sipUsername =~ s/%DOMAIN%/$thisSIPDomain/g;
                  $sipPassword = $thisSIPPassword;
                  $sipPassword =~ s/%UE_ID%/$ueStr/g;
                  $sipPassword =~ s/%DOMAIN%/$thisSIPDomain/g;


                  $sipAuthUsername = "";
                  if ($useSipAuthUsername eq "true")
                  {
                      $sipAuthUsername = $thisSipAuthUsername;
                      $sipAuthUsernameSuffix = "";
                      $position = rindex($sipAuthUsername, "+%UE_ID%");
                      if ($position != -1) {
                         if (length($sipAuthUsername) > $position + 8) {
                           $sipAuthUsernameSuffix = substr($sipAuthUsername, $position+8);
                         }
                         $numPart = substr($sipAuthUsername, 0, $position);

                         if ($numPart !~ /\D/) {
                             # Is numbers only
                             $sipAuthUsername = ($numPart+$ue).$sipAuthUsernameSuffix;
                         }
                         else {
                             # contains a prefix.
                             @numberParts = split(/\D+/, $numPart);
                             $numberPart = $numberParts[-1];
                             $position = rindex($numPart, $numberPart);
                             $prefix = substr($numPart, 0, $position);
                             $sipAuthUsername = $prefix.($numberPart+$ue).$sipAuthUsernameSuffix;
                         }
                      }

                      $sipAuthUsername =~ s/%UE_ID%/$ueStr/g;
                      $sipAuthUsername =~ s/%DOMAIN%/$thisSIPDomain/g;
                  }

                  $allowUaInitiateCalls = "false";
                  $thisCallListName = "";

                  if (defined $thisKey->[$i]->{'Mobile_Originated_Pattern'}) {
                    if ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "List") {
                      if (defined $thisKey->[$i]->{'Mobile_Originated_Call_List'}) {
                        if ($thisKey =~ /ARRAY/) {
                          $callListKey = $thisKey->[$i]->{'Mobile_Originated_Call_List'}->{'UE'};
                          if (!($callListKey =~ /ARRAY/)) {
                            $callListKey = [$thisKey->[$i]->{'Mobile_Originated_Call_List'}->{'UE'}];
                          }
                        }
                        else {
                          $callListKey = $thisKey->{'Mobile_Originated_Call_List'}->{'UE'};
                          if (!($callListKey =~ /ARRAY/)) {
                            $callListKey = [$thisKey->{'Mobile_Originated_Call_List'}->{'UE'}];
                          }
                        }
                        $j = 0;
                        foreach (@{$callListKey}) {
                          if ($callListKey->[$j]->{'UE_Id'} eq "All") {
                            $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                            $allowUaInitiateCalls = "true";
                            last;
                          }
                          if ($callListKey->[$j]->{'UE_Id'} eq "Odd") {
                            if ($ue % 2) {
                              $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                              $allowUaInitiateCalls = "true";
                              last;
                            }
                          }
                          if ($callListKey->[$j]->{'UE_Id'} eq "Even") {
                            if ($ue % 2 == 0) {
                              $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                              $allowUaInitiateCalls = "true";
                              last;
                            }
                          }
                          elsif ((index($callListKey->[$j]->{'UE_Id'}, ".") != -1) || (index($callListKey->[$j]->{'UE_Id'}, "-") != -1) || (index($callListKey->[$j]->{'UE_Id'}, ",") != -1)) {
                            for $expandedUe (0..$conf{UEs}-1) {
                              if (isInRange($ue, $callListKey->[$j]->{'UE_Id'}) == 1) {
                                $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                                $allowUaInitiateCalls = "true";
                                last;
                              }
                            }
                          }
                          elsif ($ue == $callListKey->[$j]->{'UE_Id'}) {
                            $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                            $allowUaInitiateCalls = "true";
                            last;
                          }
                          $j = $j + 1;
                        }
                      }
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "All") {
                      $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                      $allowUaInitiateCalls = "true";
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Odd") {
                      if ($ue % 2) {
                        $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                        $allowUaInitiateCalls = "true";
                      }
                    }
                    elsif ($thisKey->[$i]->{'Mobile_Originated_Pattern'} eq "Even") {
                      if ($ue % 2 == 0) {
                        $thisCallListName = $Alias.$VoipCallListId.$ueStr.$suffix;
                        $allowUaInitiateCalls = "true";
                      }
                    }

                    $thisUeConfigurePassiveAnalysis = $thisConfigurePassiveAnalysis;
                    if ($thisConfigurePassiveAnalysis eq "true") {
                      if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}) {
                        if (defined $thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Pattern'}) {
                          if ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Pattern'} eq "Odd") {
                            if ($ue % 2) {
                              $thisUeConfigurePassiveAnalysis = "true";
                            }
                            else {
                              $thisUeConfigurePassiveAnalysis = "false";
                            }
                          }
                          elsif ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Pattern'} eq "Even") {
                            if ($ue % 2 == 0) {
                              $thisUeConfigurePassiveAnalysis = "true";
                            }
                            else {
                              $thisUeConfigurePassiveAnalysis = "false";
                            }
                          }
                          elsif ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Pattern'} eq "All") {
                              $thisUeConfigurePassiveAnalysis = "true";
                          }
                          elsif ($thisKey->[$i]->{'VoIP_Passive_Analysis'}->{'Pattern'} eq "None") {
                             $thisUeConfigurePassiveAnalysis = "false";
                          }
                        }
                      }
                    }

                    if ((grep /^$thisSIPServer/,@InternalVoIPServerNames) != 0) {  # If we are to connect to a diversifEye internal server
                      $thisSIPRegisterWithServer = "false"
                    }

                    $thisVoIPAppID = $host_name."_".$thisSIPPort;

                    $thisSIPServerName = $thisSIPServer;
                    if (($SIPTransportPort != $thisSIPPort) && ($doPerPortVoIPProxy eq 1)) {
                      $thisSIPServerName = $thisSIPServer."_".$thisSIPPort;
                    }

                    if ((grep /^$thisVoIPAppID/,@VoIPApps) == 0) {  # only one VoIP type client per UE host
                      push(@VoIPApps, $thisVoIPAppID);

                      if ($doStatisticGroups) {
                        $thisAggregateGroupName = $Alias."_".$base_name;
                      }
                      else {
                        $thisAggregateGroupName = "";
                      }

                      $Tg->NewTemplate();
                      if ($VERSION >= 11) {

                        if ($thisVoLteAkaKey ne "") {
                          $thisUeVoLteAkaKey = $thisVoLteAkaKey + $ue;
                          $thisUeVoLteAkaKey = $thisUeVoLteAkaKey->as_hex();
                          $thisUeVoLteAkaKey =~ s/0x//g;

                          if ( length($thisUeVoLteAkaKey) > 32) {
                            $thisUeVoLteAkaKey = substr( $thisUeVoLteAkaKey, -32 );
                          }
                        }
                        else {
                          $thisUeVoLteAkaKey = $thisVoLteAkaKey;
                        }

                        $Tg->Add(diversifEye::VoipUa->
                        new (name=>$Alias."_".$base_name,
                        description=>$thisVoipDescription,
                        host=>$host_name,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        three_gpp_ims_multimedia_telephony_support=>$thisThreeGppImsMultimediaTelephonySupport,
                        three_gpp_sms_support=>$thisThreeGppSmsSupport,
                        sms_gateway_uri=>$thisSmsGateway,
                        message_recipient_selection=>"E.164 Number",
                        e164_number=>$thisSmsRecipient,
                        sms_message_list=>$thisMessageList,
                        enable_sms_burst=>"true",
                        inter_sms_delay=>$thisDelayBetweenSms,
                        inter_sms_delay_metric=>"ms",
                        sms_burst_count=>$thisNumberOfSmsInABurst,
                        inter_sms_burst_delay=>$thisDelayBetweenSms,
                        inter_sms_burst_delay_metric=>"ms",
                        sms_burst_delay=>$thisDelayBetweenBursts,
                        sms_burst_delay_metric=>"ms",
                        initial_sms_delay=>$thisInitialSmsDelay,
                        initial_sms_delay_metric=>"ms",
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisUeVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$sipUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$sipPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$sipAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"VoIP Call List",
                        call_list=>$thisCallListName,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>$allowUaInitiateCalls,
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        use_server_interval=>$thisUseServerInterval,
                        registration_interval=>$thisRegistrationInterval,
                        registration_interval_metric=>'secs',
                        use_client_ip_as_sip_domainname=>$thisClientIpAsDomain,
                        enable_send_100_trying=>$thisSend100Trying,
                        support_100_rel_prack=>$thisUse100RelPrack,
                        enable_session_timer=>$thisSessionTimerEnable,
                        session_timer=>$thisSessionTimer,
                        session_timer_metric=>'secs',
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        generate_rtcp_reports=>$thisGenerateRtcpReports,
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                      }
                      elsif ($VERSION >= 10.4) {

                        if ($thisVoLteAkaKey ne "") {
                          $thisUeVoLteAkaKey = $thisVoLteAkaKey + $ue;
                          $thisUeVoLteAkaKey = $thisUeVoLteAkaKey->as_hex();
                          $thisUeVoLteAkaKey =~ s/0x//g;

                          if ( length($thisUeVoLteAkaKey) > 32) {
                            $thisUeVoLteAkaKey = substr( $thisUeVoLteAkaKey, -32 );
                          }
                        }
                        else {
                          $thisUeVoLteAkaKey = $thisVoLteAkaKey;
                        }

                        $Tg->Add(diversifEye::VoipUa->
                        new (name=>$Alias."_".$base_name,
                        description=>$thisVoipDescription,
                        host=>$host_name,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        authentication_algorithm=>$thisVoLteAuthAlgorithm,
                        aka_key=>$thisUeVoLteAkaKey,
                        aka_operator_id=>$thisVoLteAkaOperatorId,
                        protected_sip_port=>$thisVoLteProtectedSipPort,
                        esp_encryption_algorithm=>$thisVoLteEspEncAlgorithm,
                        esp_authentication_algorithm=>$thisVoLteEspAuthAlgorithm,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$sipUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$sipPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$sipAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"VoIP Call List",
                        call_list=>$thisCallListName,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>$allowUaInitiateCalls,
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                      }
                      elsif ($VERSION >= 10.2) { # No VoLTE support in this version.

                        $Tg->Add(diversifEye::VoipUa->
                        new (name=>$Alias."_".$base_name,
                        description=>$thisVoipDescription,
                        host=>$host_name,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$sipUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$sipPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$sipAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"VoIP Call List",
                        call_list=>$thisCallListName,
                        stream_profile=>$stream_profile,
                        enable_amr_level_changing=>$thisEnableAmrLevelChanging,
                        level_change_list=>$thisLevelChangeList,
                        variable_level_change=>'',
                        level_change_interval=>$thisAmrLevelChangeInterval,
                        level_change_interval_metric=>'ms',
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>$allowUaInitiateCalls,
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisUeConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                      }
                      elsif ($VERSION >= 8) { # API changed and broken by Shenick.
                        $Tg->Add(diversifEye::VoipUa->
                        new (name=>$Alias."_".$base_name,
                        description=>$thisVoipDescription,
                        host=>$host_name,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        tcp_characteristics=>$TcpCharacteristicsName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        transport_type=>$thisSIPType,
                        rtp_ports=>$rtp_port_profile,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$sipUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$sipPassword,
                        specify_sip_auth_username=>$useSipAuthUsername,
                        sip_auth_username=>$sipAuthUsername,
                        sip_domain_name=>$thisSIPDomain,
                        called_party_selection=>"VoIP Call List",
                        call_list=>$thisCallListName,
                        stream_profile=>$stream_profile,
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>$allowUaInitiateCalls,
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        configure_passive_analysis=>$thisConfigurePassiveAnalysis,
                        enable_passive_analysis_statistics=>$thisPaEnablePassiveAnalysisStats,
                        playout_jitter_buffer_delay=>$thisPaPlayoutJitter,
                        playout_jitter_buffer_delay_metric=>"ms",
                        maximum_jitter_buffer=>$thisPaMaxJitter,
                        maximum_jitter_buffer_metric=>"ms",
                        media_type=>$thisPaMediaType,
                        video_codec=>$thisPaVideoCodec,
                        analyse_mpeg2ts_es=>$thisPaAnalyseMpeg2tsEs,
                        auto_determine_pid=>$thisPaAutoDeterminePid,
                        video_pid=>$thisPaVideoPid,
                        administrative_state=>$AsOther));
                      }
                      else {
                        $Tg->Add(diversifEye::VoipUa->
                        new (name=>$Alias."_".$base_name,
                        description=>$thisVoipDescription,
                        host=>$host_name,
                        is_normal_stats_enabled=>$NormalStatsEnabled,
                        is_fine_stats_enabled=>$FineStatsEnabled,
                        aggregate_group=>$thisAggregateGroupName,
                        server=>$thisSIPServerName,
                        register_with_server=>$thisSIPRegisterWithServer,
                        rtp_ports=>$rtp_port_profile ,
                        transport_port=>$thisSIPPort,
                        sip_user_name=>$sipUsername,
                        use_sip_username_as_password=>$sip_usernameaspassword,
                        sip_password=>$sipPassword,
                        sip_domain_name=>$thisSIPDomain,
                        call_list=>$thisCallListName,
                        stream_profile=>$stream_profile,
                        disable_rtp_sending=>'false',
                        allow_ua_initiate_calls=>$allowUaInitiateCalls,
                        allow_delay_between_calls=>$sip_allowdelaybetweencalls,
                        bhca=>$sip_bhca,
                        average_hold_time=>$sip_averageholdtime,
                        average_hold_time_metric=>"ms",
                        call_answering_delay=>$thisCallAnsweringDelay,
                        call_answering_delay_metric=>'ms',
                        initial_call_delay=>$thisInitialCallDelay,
                        initial_call_delay_metric=>"ms",
                        latency_stats_enabled=>$thisLatencyStats,
                        configure_passive_analysis=>'',
                        service_state=>$ServiceState,
                        start_after_metric=>'ms',
                        administrative_state=>$AsOther));
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      $i = $i + 1;
    }
  }


  ### End of Applications
}


# create thresholds
printf(STDERR "%s\n", 'Generating Thresholds ...');

if (defined $xmlHash->{'diversifEye_Configuration'}->{'Threshold_Configuration'}->{'Threshold'}) {
  $rootKey = $xmlHash->{'diversifEye_Configuration'}->{'Threshold_Configuration'}->{'Threshold'};
  $i = 0;
  $thresholdNumber = 0;
  $gt = ">";
  $lt = "<";

  if (!($rootKey =~ /ARRAY/)) {
    $rootKey = [$xmlHash->{'diversifEye_Configuration'}->{'Threshold_Configuration'}->{'Threshold'}];
  }

  foreach (@{$rootKey}) {
    if ((defined $rootKey->[$i]->{'Name'}) && (defined $rootKey->[$i]->{'Rule'}) && (defined $rootKey->[$i]->{'Regular_Expression'}) && (defined $rootKey->[$i]->{'Start_Test_Delay'}) && (defined $rootKey->[$i]->{'Event_Tag'})) {
      $thresholdName = cleanXmlAmp($rootKey->[$i]->{'Name'});
      $thresholdRule = cleanXmlAmp($rootKey->[$i]->{'Rule'});
      $thresholdRegular_Expression = cleanXmlAmp($rootKey->[$i]->{'Regular_Expression'});
      $thresholdStart_Test_Delay = $rootKey->[$i]->{'Start_Test_Delay'};
      $thresholdEvent_Tag = cleanXmlAmp($rootKey->[$i]->{'Event_Tag'});

      $thresholdViolation_Delay_Enabled ="false";
      $thresholdViolation_Delay = "";
      $thresholdClear_Delay_Enabled = "false";
      $thresholdClear_Delay = "";

      if (defined $rootKey->[$i]->{'Violation_Trigger'}) {
        if ( ($rootKey->[$i]->{'Violation_Trigger'} > 0) && ($rootKey->[$i]->{'Violation_Trigger'} <= 2147483647) ) {
          $thresholdViolation_Delay_Enabled = "true";
          $thresholdViolation_Delay = $rootKey->[$i]->{'Violation_Trigger'};
        }
      }

      if (defined $rootKey->[$i]->{'Clear_Trigger'}) {
        if ( ($rootKey->[$i]->{'Clear_Trigger'} > 0) && ($rootKey->[$i]->{'Clear_Trigger'} <= 2147483647) ) {
          $thresholdClear_Delay_Enabled = "true";
          $thresholdClear_Delay = $rootKey->[$i]->{'Clear_Trigger'};
        }
      }

      if ($thresholdNumber > 0) {
        $Tg->NewTemplate();
      }
      $Tg->Add(diversifEye::Threshold->new(name=>$thresholdName, rule=>$thresholdRule, regular_expression=>$thresholdRegular_Expression, start_test_delay=>$thresholdStart_Test_Delay, start_test_delay_metric=>"secs", statistics_type=>"Normal", enabled_violation_delay=>$thresholdViolation_Delay_Enabled, violation_delay=>$thresholdViolation_Delay, enabled_clear_delay=>$thresholdClear_Delay_Enabled, clear_delay=>$thresholdClear_Delay, event_tag=>$thresholdEvent_Tag));

      $thresholdNumber = $thresholdNumber + 1;
    }
    $i = $i + 1;
  }
}
$Tg->End();

### Global Settings
printf(STDERR "Global Settings\n");
if (($VERSION >= 11.3) && ($PooledConfig == 0)) {  # Not yet supported for Pool Manager Mode.
  $rootKey = $xmlHash->{'diversifEye_Configuration'};
  if (defined $rootKey->{'Global_Settings'}) {
    $thisKey = $rootKey->{'Global_Settings'};
    $postData = "";

    if (defined $thisKey->{'Wireless_call_answering_with_183_180_responses'}) {
       if ( lc($thisKey->{'Wireless_call_answering_with_183_180_responses'}) eq "true") {
         $paramName = getGlobalParamName("voip_client_settings","3gpp_wireless_call_answering_with_183180_responses");
         if ($paramName ne "") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=".getGlobalParamValue($paramName);
         }
      }
    }

    if (defined $thisKey->{'Send_early_media_if_183_session_progress_received'}) {
       if ( lc($thisKey->{'Send_early_media_if_183_session_progress_received'}) eq "true") {
         $paramName = getGlobalParamName("voip_client_settings","183_session");
         if ($paramName ne "") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=".getGlobalParamValue($paramName);
         }
      }
    }

    if (defined $thisKey->{'Route_SIP_responses_using_VIA_field'}) {
       if ( lc($thisKey->{'Route_SIP_responses_using_VIA_field'}) eq "true") {
         $paramName = getGlobalParamName("voip_client_settings","route_sip_responses_using_the_via_field_of_request");
         if ($paramName ne "") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=".getGlobalParamValue($paramName);
         }
      }
    }

    if (defined $thisKey->{'SIP_Enable_PANI_headers'}) {
       if ( lc($thisKey->{'SIP_Enable_PANI_headers'}) eq "true") {
         $paramName = getGlobalParamName("sip_field_settings","enable_pani_headers");
         if ($paramName ne "") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=".getGlobalParamValue($paramName);
         }
      }
    }

    # none = "" (default), IEEE-802.11a = 0, IEEE-802.11b = 1, 3GPP-GERAN = 2, 3GPP-UTRAN-FDD = 3, 3GPP-UTRAN-TDD = 4, 3GPP-CDMA2000 = 5
    if (defined $thisKey->{'SIP_Access_Type'}) {
      $paramName = getGlobalParamName("sip_field_settings","access_type");
      if ($paramName ne "") {
         if ( lc($thisKey->{'SIP_Access_Type'}) eq "ieee-802.11a") {
             if ($postData ne "") {
                $postData .= "&";
             }
             $postData .= $paramName."=0";
         }
         elsif ( lc($thisKey->{'SIP_Access_Type'}) eq "ieee-802.11b") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=1";
         }
         elsif ( lc($thisKey->{'SIP_Access_Type'}) eq "3gpp-geran") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=2";
         }
         elsif ( lc($thisKey->{'SIP_Access_Type'}) eq "3gpp-utran-fdd") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=3";
         }
         elsif ( lc($thisKey->{'SIP_Access_Type'}) eq "3gpp-utran-tdd") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=4";
         }
         elsif ( lc($thisKey->{'SIP_Access_Type'}) eq "3gpp-cdma2000") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=5";
         }
      }
    }

    # none =  "" (default), cgi-3gpp = 0, utran-cell-id-3gpp = 1, extension-access-info = 2,
    if (defined $thisKey->{'SIP_Access_Info'}) {
      $paramName = getGlobalParamName("sip_field_settings","access_info");
      if ($paramName ne "") {
         if ( lc($thisKey->{'SIP_Access_Info'}) eq "cgi-3gpp") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=0";
         }
         elsif ( lc($thisKey->{'SIP_Access_Info'}) eq "utran-cell-id-3gpp") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=1";
         }
         elsif ( lc($thisKey->{'SIP_Access_Info'}) eq "extension-access-info") {
            if ($postData ne "") {
               $postData .= "&";
            }
            $postData .= $paramName."=2";
         }
      }
    }

    if (defined $thisKey->{'SIP_Access_Value'}) {
      if ($thisKey->{'SIP_Access_Value'} ne "") {
         $paramName = getGlobalParamName("sip_field_settings","access_value");
         if ($paramName ne "") {
            if ($postData ne "") {
                $postData .= "&";
            }
            $postData .= $paramName."=".$thisKey->{'SIP_Access_Value'};
         }
      }
    }

    if (defined $thisKey->{'SIP_Number_of_Response_Fields'}) {
       if ($thisKey->{'SIP_Number_of_Response_Fields'} ne "") {
         $paramName = getGlobalParamName("sip_field_settings","number_of_sip_response_fields");
         if ($paramName ne "") {
            if ($postData ne "") {
                $postData .= "&";
            }
            $postData .= $paramName."=".$thisKey->{'SIP_Number_of_Response_Fields'};
         }
      }
    }

    if ($postData ne "") {
       $postData .= "&submit=Save";
       $postData =~ s/&quot;/"/g;
       $postData =~ s/%/%25/g;
       printf(STDERR "%s\n", 'Configuring Global Settings ...');

       # Now post the data using wget to each Interface Page.
       foreach my $interface (@PARTITION_INTERFACES) {
          printf(STDERR "Posting Global Settings for interface %s\n", $interface);
          #printf(STDERR "DEBUG: postData=%s\n", $postData);
          qx/wget -q --post-data '$postData' http:\/\/diverAdmin:diversifEye\@127.0.0.1:$ADMIN_PAGE_PORT\/admin\/global\/index.php?pp=$interface\/1 -O -/;
       }
    }
  }
}

printf(STDERR "%s\n", "Generation of Test Group Complete");
