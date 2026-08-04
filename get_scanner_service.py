import sys

def main():
    with open('lib/services/scanner_service.dart', 'r') as f:
        content = f.read()
        print(content)

if __name__ == '__main__':
    main()
