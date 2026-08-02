curl -s https://pub.dev/api/search?q=document_scanner | grep -oP '"package":"\K[^"]+' | head -n 5
curl -s https://pub.dev/api/search?q=edge_detection | grep -oP '"package":"\K[^"]+' | head -n 5
