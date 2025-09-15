# Display all Wifi and their passwords saved on this PC
(netsh wlan show profiles) | 
    Select-String "All User Profile" | 
    %{$name=$_.Line.Split(':')[1].Trim().Replace('"',''); $_} | 
    %{(netsh wlan show profile name="$name" key=clear)} | 
    Select-String "Key Content" | 
    %{$password=$_.Line.Split(':')[1].Trim(); 
    [PSCustomObject]@{WIFI_NAME=$name; PASSWORD=$password}} |
    Sort-Object WIFI_NAME