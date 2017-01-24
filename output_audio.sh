rm -rf audio
mkdir audio
cd audio
echo "track 0" > run_audio.scr

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
            [) state="a";
               ;;
            ]) state="e";
               ;;
            esac
            ;;
        a)  case "$char" in
            ,) write_sample
               ;;
            ]) write_sample
               state="t"
               ;;
            *) cur_sample+=$char
               ;;
            esac
            ;;
    esac
done < temp

ffmpeg -f s16le -ar 44.1k -ac 2 -i audio.pcm audio.wav
