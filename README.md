# 一件安装sing-box

<details>
    <summary>(点击展开)</summary>
 
```
wget -N -O /usr/local/bin/anytls-reality.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/AnyTLSReality.sh \
  && chmod +x /usr/local/bin/anytls-reality.sh \
  && bash /usr/local/bin/anytls-reality.sh
```
  或
```
wget -N -O /usr/local/bin/anytls-reality.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/AnyTLSReality.sh \
  && chmod +x /usr/local/bin/anytls-reality.sh \
  && ln -sf /usr/local/bin/anytls-reality.sh /usr/local/bin/anytls \
  && bash /usr/local/bin/anytls-reality.sh
```
</details>
检查配置：
sing-box check -c /usr/local/etc/sing-box/anytls.jsonsing-box check -c /usr/local/etc/sing-box/reality.json
重启服务：
systemctl restart sing-box-anytls.servicesystemctl restart sing-box-reality.service
看状态：
systemctl status sing
