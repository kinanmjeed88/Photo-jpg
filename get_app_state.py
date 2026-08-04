import sys

def main():
    with open('lib/providers/app_state.dart', 'r') as f:
        content = f.read()
        print(content)

if __name__ == '__main__':
    main()
