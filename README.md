# profile

My default linux profile


```
root@server:/tmp/found# tar -xvfz /usr/share/games/archive/file/here/EP0LQ0w0oB9xkC.tar.gz
tar: z: Cannot open: No such file or directory
tar: Error is not recoverable: exiting now
```
Почему-то не сработало. Проверяем:
```
root@server:/tmp/found# tar -ztvf /usr/share/games/archive/file/here/EP0LQ0w0oB9xkC.tar.gz
-rw-r--r-- root/root         5 2021-07-19 04:00 file1.txt
```
Все на месте. Пришлось гуглить. Вариант без "-" почему-то запустился. 
```
root@server:/tmp/found# tar xvfz /usr/share/games/archive/file/here/EP0LQ0w0oB9xkC.tar.gz
file1.txt
```
:confused:
