import sys

def main():
    with open('lib/screens/scanner_screen.dart', 'r') as f:
        content = f.read()
        print(content)

if __name__ == '__main__':
    main()
