@echo off
set tma_path=%~f1
set aflx_python_script_name=shenick.py
set aflx_ip_addr=192.168.10.200
set aflx_group_name=RDA_Script_Template
set aflx_rat=LTE
set aflx_ftp_user=cli
set aflx_ftp_password=diversifEye
set aflx_ftp_script=ftp_script.txt
set aflx_part=1

if ["%tma_path%"] EQU [""] goto skipPathChange

:changePath
echo.
echo adding tma_path %tma_path%
echo.
set aflx_python_script_name=%tma_path%\%aflx_python_script_name% 


:skipPathChange


echo.
echo Removing remotely generated XML file before we start...
echo.

echo %aflx_ftp_user%> %aflx_ftp_script%
echo %aflx_ftp_password%>> %aflx_ftp_script%
echo delete %aflx_group_name%.xml>> %aflx_ftp_script%
echo bye>> %aflx_ftp_script%
ftp -s:%aflx_ftp_script% %aflx_ip_addr%
del %aflx_ftp_script%

echo.
echo Start remote provisioning
echo.

python "%aflx_python_script_name%" %aflx_ip_addr% -p %aflx_part% -c provision -g %aflx_group_name% -r %aflx_rat% -t "%tma_path%"
if %ERRORLEVEL% neq 0 goto Failed

echo.
echo Remote provisioning complete.... fetching generated XML file
echo.

:getGenXml
echo %aflx_ftp_user%> %aflx_ftp_script%
echo %aflx_ftp_password%>> %aflx_ftp_script%
echo get %aflx_group_name%.xml>> %aflx_ftp_script%
echo bye>> %aflx_ftp_script%

ftp -s:%aflx_ftp_script% %aflx_ip_addr%

del %aflx_ftp_script%
goto End


:Failed
echo.
echo There was a failure from the python script %aflx_python_script_name%
echo.
goto getGenXml

:End
rem Clear the environment variables created by us.
set aflx_python_script_name=
set aflx_ip_addr=
set aflx_group_name=
set aflx_ftp_user=
set aflx_ftp_password=
set aflx_ftp_script=
set aflx_part=