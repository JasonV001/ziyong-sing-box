# 一件安装sing-box

<details>
    <summary>(点击展开)</summary>
 
```
wget -N -O /usr/local/bin/anytls-reality.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/anytls-reality.sh && chmod +x /usr/local/bin/anytls-reality.sh && bash /usr/local/bin/anytls-reality.sh
```
# 再次运行
```
bash /usr/local/bin/anytls-reality.sh
```
</details>

# 手动开机重启sing-box

```

ps aux | grep sing-box  # 查看进程是否存在
ps aux | grep anytls

```


```
nohup /usr/local/bin/sing-box run -c /usr/local/etc/sing-box/reality.json
```
