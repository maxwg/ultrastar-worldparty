@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /W4 /WX /O2 /MT /DUNICODE /D_UNICODE /Fe:burst_fixture.exe /Fo:burst_fixture.obj burst_fixture.c /link /SUBSYSTEM:CONSOLE
