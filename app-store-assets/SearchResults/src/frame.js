// The design frame is always 3840 wide; its height follows the viewport (2560 for 3:2, 2160 for 16:9).
const FH = Math.round((innerHeight * 3840) / innerWidth);
stage.style.height = FH + 'px';

const headlineHTML = 'Write it down.<span class="l2">It comes <span class="hl">back</span><svg class="loop"><use href="#loop" /></svg></span>';
