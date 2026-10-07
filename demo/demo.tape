Output media/demo.gif
Set Shell "bash"
Set FontSize 16
Set Width 1360
Set Height 940
Set Framerate 5
Set Padding 12
Set Theme "Catppuccin Mocha"
Hide
Type "python3 demo/run.py dark wide"
Enter
Sleep 3s
Show
Sleep 4s
Ctrl+Q
Hide
Sleep 1s
Type "python3 demo/run.py dark narrow"
Enter
Sleep 3s
Show
Sleep 4s
Ctrl+Q
Hide
Sleep 1s
Type "python3 demo/run.py light narrow"
Enter
Sleep 3s
Show
Sleep 4s
Ctrl+Q
Hide
Sleep 1s
