### For Tree-sitter

- Install git (not required on newer versions of Windows 10, tar is installed and curl is bundled with Neovim).
- Install [gcc - https://techdecodetutorials.com/download/](https://techdecodetutorials.com/download/ "64 bit mingw/gcc installer").
- Setup environment:
```
  INCLUDE: C:\MinGW\include
  LIB: C:\MinGW\lib
```
- Install parsers in Neovim via ```:TSInstall c```, ```:TSInstall cpp```
