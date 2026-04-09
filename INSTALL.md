# Quick Install

```bash
scp setup_loop_player.sh youruser@<PI-IP>:~/setup_loop_player.sh
ssh youruser@<PI-IP>
sed -i 's/\r$//' ~/setup_loop_player.sh
chmod +x ~/setup_loop_player.sh
sudo ~/setup_loop_player.sh
```
