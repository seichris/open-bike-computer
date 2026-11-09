This demo is built on the Linux platform, compiled using a cross-compiler, and runs on Raspberry Pi 4b.
usage:
1.Install a cross-compiler with the same architecture as Raspberry Pi 4b
Using " uname -a " command to view architecture of Raspberry Pi 4b
2.Modify the "CC" variable in the makefile to the installed cross compiler
3.Using make command build project to obtain the product.
4.Move the product to Raspberry Pi 4b.
5.Running project with "sudo ./" .