rm -rf audio
mkdir audio
cd audio
echo "track [[[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]], [[440, 0], [440, 5512], [220, 0], [220, 5512]]]"  > run_audio.scr

../.cabal-sandbox/bin/cryptol ../examples/funstuff/sincos.cry -b run_audio.scr > temp

state="s"
cur_sample=""

write_sample() {
    local sample="${cur_sample/0x/\\x}"
    echo -en "$sample" >> audio.pcm
    cur_sample=""
}

while read -n1 char; do
    case "$state" in
        s)  if [ "$char" == "[" ]; then
                state="t" 
            fi
            ;;
        t)  case "$char" in
            [) state="f";
               ;;
            ]) state="e";
               ;;
            esac
            ;;
        f)  case "$char" in
            [) state="a";
               ;;
            ]) state="t";
               ;;
            esac
            ;;
        a)  case "$char" in
            ,) write_sample
               ;;
            ]) write_sample
               state="f"
               ;;
            *) cur_sample+=$char
               ;;
            esac
            ;;
    esac
done < temp

ffmpeg -f s16be -ar 22.05k -ac 2 -i audio.pcm audio.wav
