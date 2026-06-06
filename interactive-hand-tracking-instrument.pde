/*
 * - 프로젝트명: 인터랙티브 핸드 트래킹 악기 연주
 * - 기능: 웹캠으로 손(특정 색상)을 인식하여 피아노, 드럼, 기타를 연주하는 프로그램
 * - 주요 로직
 *   1. OpenCV 없이 픽셀 컬러 트래킹 알고리즘 사용
 *   2. 화면을 분할하여 좌측은 캠, 우측은 악기 UI 배치
 *   3. 아두이노 시리얼 통신을 통한 악기 모드 변경
 */

import processing.video.*;
import processing.sound.*;
import processing.serial.*;
Serial myPort;
Capture video;

// 조이스틱 변수
float joyX = 0; // 아두이노에서 받은 X값 0~1023
int joystickIndex = 0; // 현재 하이라이트된 악기: 0=piano,1=drum,2=guitar
float previousJoyX=0; //조이스틱 이전 아날로그 값 - 오버시 고정을 위해
boolean joystickPressed = false; // 버튼 눌림 상태
boolean instrumentSelected = false; // 악기 선택 완료 여부

// 악기 상태: -1=start, 0=piano, 1=drum, 2=guitar
int currentInstrument = -1;

// UI 마우스 오버 상태
int hoveredInstrument = -1;

//마우스 하이라이트 제어권 체크
boolean isMouseControlling = false;

// 피아노 소리
SoundFile[] whiteSounds;
SoundFile[] blackSounds;
boolean[] isWhiteKeyPressed;
boolean[] isBlackKeyPressed;

// 기타 소리
SoundFile[] guitarSounds;
boolean[] isGuitarStringPressed;

// 드럼 소리
SoundFile[] drumSounds;
boolean[] isDrumHit;

// 컬러 트래킹
color trackColor1, trackColor2;
float threshold = 25;
float lerpX1=0, lerpY1=0, lerpX2=0, lerpY2=0;

// 웹캠 해상도
int camW = 640, camH = 480;

// 피아노 키
int numWhiteKeys = 7;
float whiteKeyWidth, blackKeyWidth, blackKeyHeight = 250;

// 이미지
PImage pianoBG, drumBG, guitarBG;

// 피아노 파티클 리스트
ArrayList<PianoParticle> pianoParticles = new ArrayList<PianoParticle>();

void setup() {
  size(1280, 480);
  // 시리얼 포트 연결 (아두이노 포트에 맞게 변경)
  String portName = Serial.list()[0];
  myPort = new Serial(this, "COM15", 9600);

  // 배경 이미지 로드
  pianoBG = loadImage("img/piano.jpg");
  drumBG = loadImage("img/drum.jpg");
  guitarBG = loadImage("img/guitar.jpg");

  // --- 이미지 블러 처리 ---
  pianoBG.filter(BLUR, 5);
  drumBG.filter(BLUR, 5);
  guitarBG.filter(BLUR, 5);

  // 웹캠 초기화
  String[] cameras = Capture.list();
  if (cameras.length==0) {
    println("No camera found.");
    exit();
  }
  video = new Capture(this, camW, camH, cameras[0]);
  video.start();

  // 초기 추적 색상
  trackColor1 = color(255, 0, 0);
  trackColor2 = color(0, 0, 255);

  // 피아노 초기화
  whiteKeyWidth = camW/numWhiteKeys;
  blackKeyWidth = whiteKeyWidth*0.6;
  loadPianoSounds();

  // 기타/드럼 초기화
  loadGuitarSounds();
  loadDrumSounds();
  setupDrumLayout();
}
void captureEvent(Capture video) {
  video.read();
}

void draw() {
  if (currentInstrument==-1) {
    // 1. 초기 배경 UI
    background(0);
    PImage currentBG = null;
    if (joystickIndex == 0) currentBG = pianoBG; //피아노 배경
    else if (joystickIndex == 1) currentBG = drumBG; //드럼 배경
    else if (joystickIndex == 2) currentBG = guitarBG; //기타 배경
    if (currentBG != null) {
      image(currentBG, 0, 0, width, height);
      noStroke();
      fill(100, 70, 0, 100);
      rect(0, 0, width, height);
      fill(0, 0, 0, 150);
      rect(0, 0, width, 10);
      rect(0, height-10, width, 10);
      rect(0, 0, 10, height);
      rect(width-10, 0, 10, height);
    }
    fill(255);
    textAlign(CENTER);
    textSize(48);
    text("Interactive Music Studio", width/2, height/2 - 100); //제목
    textSize(18);
    text("Select your virtual instrument with a touch of color.", width/2, height/2 - 50); //프로그램 소개

    // 2. 조이스틱 기반 인덱스 계산
    int joyBasedIndex;
    if (joyX < 341) joyBasedIndex = 0;
    else if (joyX < 682) joyBasedIndex = 1;
    else joyBasedIndex = 2;

    // 3. 마우스 오버 체크 (조이스틱 없을 때 테스트용)
    int hovered = -1;
    if (mouseY > height/2 + 20 && mouseY < height/2 + 70) {
      if (mouseX > 150 && mouseX < 350) hovered = 0;
      else if (mouseX > 450 && mouseX < 650) hovered = 1;
      else if (mouseX > 750 && mouseX < 950) hovered = 2;
    }
    if (!instrumentSelected) {
      if (hovered != -1) {
        //고정 시작
        joystickIndex = hovered;
        isMouseControlling = true;
      } else if (isMouseControlling) {
        // 고정 유지
        boolean joystickHasMoved = abs(joyX - previousJoyX) > 50; //조이스틱 움직임 감지
        if (joystickHasMoved) {
          isMouseControlling = false; // 잠금 해제
          joystickIndex = joyBasedIndex; // 조이스틱 인덱스 선정
        }
      } else {
        // 마지막 인덱스 고정
        joystickIndex = joyBasedIndex;
      }
    }

    // 다음 프레임을 위해 현재값 저장
    previousJoyX = joyX;

    // 4. 버튼 UI
    drawInstrumentButtons();

    // 5. 조이스틱으로 버튼 선택
    if (joystickPressed && !instrumentSelected) {
      currentInstrument = joystickIndex;
      instrumentSelected = true;
      joystickPressed = false;
      lerpX1=lerpY1=lerpX2=lerpY2=0;
    }
  } else {
    // ---------- 악기 화면 ----------
    background(0); // 검정 배경

    // 색상 추적 작동
    video.loadPixels();
    drawWebcamAndTrack();

    // Back 버튼
    drawBackButton();

    pushMatrix();
    translate(640, 0);
    switch(currentInstrument) {
    case 0:
      drawPianoUI();
      break;
    case 1:
      drawDrumUI();
      break;
    case 2:
      drawGuitarUI();
      break;
    }
    fill(trackColor1);
    stroke(255);
    strokeWeight(3);
    ellipse(lerpX1, lerpY1, 30, 30);
    fill(trackColor2);
    ellipse(lerpX2, lerpY2, 30, 30);
    popMatrix();
  }
}

// ------------------ Back 버튼 UI ------------------
void drawBackButton() {
  // 버튼 스타일
  int borderColor = color(255, 240, 200);
  noFill();
  // 버튼 배경
  stroke(borderColor);
  strokeWeight(3);
  rect(10, 10, 100, 50, 12);

  // 텍스트
  fill(255, 240, 200);
  textSize(22);
  textAlign(CENTER, CENTER);
  text("BACK", 60, 35);
}


// ------------------ 시리얼 읽기 ------------------
void serialEvent(Serial p) {
  String inStr = p.readStringUntil('\n');
  if (inStr != null) {
    inStr = trim(inStr);
    String[] values = split(inStr, ',');
    if (values.length >= 3) {
      joyX = float(values[0]);         // X축
      joystickPressed = int(values[2])==1; // 버튼 눌림
    }
  }
}

// ------------------ 악기 선택 UI 버튼 ----------------
// 0=piano,1=drum,2=guitar
int[] buttonColors = new int[3];
String[] instrumentNames ={"PIANO", "DRUM", "GRUITAR"};
void drawInstrumentButtons() {
  // 버튼 위치 정의
  float[] buttonX = {250, 640, 1030}; // 중앙 X 좌표
  float buttonY = height / 2 + 50;   // Y축 중앙보다 아래에 배치하여 제목과 구분

  for (int i = 0; i < 3; i++) {
    boolean isHighlighted = (currentInstrument == -1 && joystickIndex == i);
    boolean isSelected = (currentInstrument == i);

    if (isHighlighted || isSelected) {
      fill(255, 240, 200);
      textSize(36);
      if (isSelected) {
        stroke(180, 150, 50);
      } else {
        stroke(255, 255, 200, 200);
      }
      strokeWeight(2);
    } else {
      fill(255, 255, 255, 180);
      textSize(28);
      noStroke();
    }
    textAlign(CENTER, CENTER);
    // 텍스트 그리기
    text(instrumentNames[i], buttonX[i], buttonY);

    // 하이라이트 선택 시 얇은 테두리 효과
    if (isHighlighted || isSelected) {
      float rectW = textWidth(instrumentNames[i]) + 60;
      float rectH = 50;
      // 텍스트 주변에 얇은 사각형 테두리
      noFill();
      rectMode(CENTER);
      rect(buttonX[i], buttonY, rectW, rectH, 5);
      rectMode(CORNER);
    }
  }
}

// ------------------ 마우스 클릭 ------------------
void mousePressed() {
  // Back 버튼
  if (currentInstrument!=-1 && mouseX>10 && mouseX<110 && mouseY>10 && mouseY<60) {
    currentInstrument=-1;
    instrumentSelected = false;
    lerpX1=lerpY1=lerpX2=lerpY2=0;
    return;
  }

  // 악기 선택 버튼
  if (currentInstrument==-1 && mouseY > height/2 + 20 && mouseY < height/2 + 70) {
    if (mouseX>150 && mouseX<350) joystickIndex=0;
    else if (mouseX>450 && mouseX<650) joystickIndex=1;
    else if (mouseX>750 && mouseX<950) joystickIndex=2;

    currentInstrument = joystickIndex;
    instrumentSelected = true; // 선택 고정
    lerpX1=lerpY1=lerpX2=lerpY2=0;
    return;
  }

  // 악기 화면에서 색상 선택
  if (currentInstrument!=-1 && mouseX<camW && mouseY<camH) {
    // video 객체가 null이 아닐 때만 픽셀에 접근
    if (video != null && video.pixels != null) {
      int reverseX = camW - mouseX;
      reverseX = constrain(reverseX, 0, camW-1);
      int loc = reverseX + mouseY*video.width;
      color c = video.pixels[loc];
      if (mouseButton==LEFT) trackColor1=c;
      else if (mouseButton==RIGHT) trackColor2=c;
    }
  }
}

// ------------------ 피아노 ------------------
void drawPianoUI() {
  // 파티클
  for (int i = pianoParticles.size() - 1; i >= 0; i--) {
    PianoParticle p = pianoParticles.get(i);
    p.update();
    p.display();
    if (p.isFinished()) pianoParticles.remove(i);
  }

  stroke(0);
  strokeWeight(1);
  int keyStartY = 260;
  int keyHeight = height - keyStartY;
  float currentBlackKeyHeight = 160;

  // 흰 건반
  for (int i=0; i<numWhiteKeys; i++) {
    float x = i * whiteKeyWidth;

    boolean touch1 = (lerpX1 > x && lerpX1 < x + whiteKeyWidth && lerpY1 > keyStartY);
    boolean touch2 = (lerpX2 > x && lerpX2 < x + whiteKeyWidth && lerpY2 > keyStartY);
    boolean isTouching = touch1 || touch2;

    if (isTouching) {
      fill(200, 200, 255);
      if (isWhiteKeyPressed[i] == false) {
        whiteSounds[i].play();
        isWhiteKeyPressed[i] = true;

        // 선택한 손의 색상 결정
        color particleColor = touch1 ? trackColor1 : trackColor2;

        // 흰 건반 파티클 생성
        addPianoParticles(x + whiteKeyWidth/2, keyStartY, particleColor);
      }
    } else {
      fill(255);
      isWhiteKeyPressed[i] = false;
    }
    rect(x, keyStartY, whiteKeyWidth, keyHeight);
  }

  // 검은 건반
  int[] blackKeyIndices = {0, 1, 3, 4, 5};
  for (int i=0; i<blackKeyIndices.length; i++) {
    int keyIndex = blackKeyIndices[i];
    float x = (keyIndex + 1) * whiteKeyWidth - (blackKeyWidth / 2);

    boolean touch1 = (lerpX1 > x && lerpX1 < x + blackKeyWidth && lerpY1 > keyStartY && lerpY1 < keyStartY + currentBlackKeyHeight);
    boolean touch2 = (lerpX2 > x && lerpX2 < x + blackKeyWidth && lerpY2 > keyStartY && lerpY2 < keyStartY + currentBlackKeyHeight);
    boolean isTouching = touch1 || touch2;

    fill(0);
    if (isTouching) {
      fill(50, 50, 50);
      if (isBlackKeyPressed[i] == false) {
        blackSounds[i].play();
        isBlackKeyPressed[i] = true;

        // 선택한 손의 색상 결정
        color particleColor = touch1 ? trackColor1 : trackColor2;

        // 검은 건반 파티클 생성
        addPianoParticles(x + blackKeyWidth/2, keyStartY, particleColor);
      }
    } else {
      isBlackKeyPressed[i] = false;
    }
    rect(x, keyStartY, blackKeyWidth, currentBlackKeyHeight);
  }
}

// 파티클 생성
void addPianoParticles(float x, float y, color c) {
  for (int i=0; i<10; i++) { // 개수 약간 증가
    pianoParticles.add(new PianoParticle(x, y, c));
  }
}

// 피아노 파티클
class PianoParticle {
  PVector position;
  PVector velocity;
  float lifespan;
  color c;

  // 색상을 받아서 저장
  PianoParticle(float x, float y, color _c) {
    position = new PVector(x, y);
    // 위쪽으로 퍼지도록 속도 조절
    velocity = new PVector(random(-2, 2), random(-3, -0.5));
    lifespan = 255.0;
    c = _c;
  }

  void update() {
    position.add(velocity);
    lifespan -= 4.0; // 사라지는 속도
  }

  void display() {
    noStroke();
    fill(c, lifespan); // 저장된 색상 사용
    ellipse(position.x, position.y, 8, 8); // 크기 조절
  }

  boolean isFinished() {
    return (lifespan < 0.0);
  }
}

// 피아노 사운드
void loadPianoSounds() {
  String[] whiteFileNames = { "piano/C4.mp3", "piano/D4.mp3", "piano/E4.mp3", "piano/F4.mp3", "piano/G4.mp3", "piano/A4.mp3", "piano/B4.mp3" };
  String[] blackFileNames = { "piano/C#4.mp3", "piano/D#4.mp3", "piano/F#4.mp3", "piano/G#4.mp3", "piano/A#4.mp3" };

  whiteSounds = new SoundFile[numWhiteKeys];
  isWhiteKeyPressed = new boolean[numWhiteKeys];
  blackSounds = new SoundFile[5];
  isBlackKeyPressed = new boolean[5];

  for (int i=0; i<numWhiteKeys; i++) {
    whiteSounds[i] = new SoundFile(this, whiteFileNames[i]);
    isWhiteKeyPressed[i] = false;
  }
  for (int i=0; i<5; i++) {
    blackSounds[i] = new SoundFile(this, blackFileNames[i]);
    isBlackKeyPressed[i] = false;
  }
}

// ------------------ 기타 ------------------
float[] stringOffset = new float[6];
float[] stringVibration = new float[6];
float[] stringDecay = new float[6];
float[] stringThickness = {2, 3, 4, 5, 6, 7};
ArrayList<GuitarParticle> guitarParticles = new ArrayList<GuitarParticle>();

void drawGuitarUI() {
  int startY = height/2 - 100;
  int stringHeight = 45;
  for (int i=0; i<6; i++) {
    if (stringDecay[i] > 0.001) {
      stringOffset[i] = sin(frameCount * 0.4) * stringVibration[i];
      stringVibration[i] *= 0.92;
      stringDecay[i] *= 0.92;
    } else {
      stringOffset[i] = 0;
      stringVibration[i] = 0;
    }
    float y = startY + i*stringHeight + stringOffset[i];

    // ---- 기타 색 표현 ----
    color stringColor;
    if (i == 0 || i == 1) stringColor = color(230);
    else if (i == 2)      stringColor = color(210);
    else                  stringColor = color(150, 120, 80);
    // 금속 표현 (노이즈)
    float shine = map(noise(frameCount*0.02 + i*10), 0, 1, -20, 20);
    stringColor = color(red(stringColor)+shine, green(stringColor)+shine, blue(stringColor)+shine);
    strokeWeight(stringThickness[i]);
    stroke(stringColor);
    // 기타 줄
    line(width/4 - 300, y, width/4 + 300, y);

    // ---- 손 접촉 체크 ----
    boolean touch1 = abs(lerpY1 - y) < 18;
    boolean touch2 = abs(lerpY2 - y) < 18;
    boolean isTouching = touch1 || touch2;
    if (isTouching) {
      if (!isGuitarStringPressed[i]) {
        guitarSounds[i].play();
        isGuitarStringPressed[i] = true;
        // 줄 진동
        stringVibration[i] = 10;
        stringDecay[i] = 1;
        // 손 색상 기반 파티클
        color c = touch1 ? trackColor1 : trackColor2;
        for (int p=0; p<10; p++) {
          float px = random(width/4 - 300, width/4 + 300);
          guitarParticles.add(new GuitarParticle(px, y, c, i));
        }
      }
    } else {
      isGuitarStringPressed[i] = false;
    }
  }
  // 파티클 업데이트
  for (int j=guitarParticles.size()-1; j>=0; j--) {
    GuitarParticle p = guitarParticles.get(j);
    p.update();
    p.display();
    if (p.isFinished()) guitarParticles.remove(j);
  }
}

// ------------------ 기타 파티클 ------------------
class GuitarParticle {
  float x, y;
  color c;
  float alpha = 255;
  float size = 5;
  float speedY;
  float speedX;
  int stringIndex;

  GuitarParticle(float x, float y, color c, int stringIndex) {
    this.x = x;
    this.y = y;
    this.c = c;
    this.stringIndex = stringIndex;
    this.speedY = random(-2, 2);
    this.speedX = random(-1.5, 1.5);
  }
  void update() {
    x += speedX;
    y += speedY;
    alpha -= 5;
    size += 0.3;
  }
  void display() {
    noStroke();
    fill(c, alpha);
    ellipse(x, y, size, size);
    ellipse(x, y + size*1.5, size*0.7, size*0.7);
    ellipse(x, y - size*1.5, size*0.7, size*0.7);
  }
  boolean isFinished() {
    return alpha <= 0;
  }
}

//기타 사운드
void loadGuitarSounds() {
  String[] files = {"guitar/HighE.mp3", "guitar/B.mp3", "guitar/G.mp3", "guitar/D.mp3", "guitar/A.mp3", "guitar/LowE.mp3"};
  guitarSounds = new SoundFile[6];
  isGuitarStringPressed = new boolean[6];
  stringOffset = new float[6];
  for (int i=0; i<6; i++) {
    guitarSounds[i] = new SoundFile(this, files[i]);
    isGuitarStringPressed[i] = false;
    stringOffset[i] = 0;
  }
}

// ------------------ 드럼 ------------------
float[] drumX = new float[8];
float[] drumY = new float[8];
float[] drumBaseR = new float[8];
float[] drumCurrentR = new float[8];
ArrayList<DrumRipple> ripples = new ArrayList<DrumRipple>();

// 파형
float waveEnergy = 0;
float waveDecay = 0.92;

// 배경 흔들림
float bgNoise = 0;
float bgPulse = 0;

// ------------------ 드럼 UI 배치 ------------------
void setupDrumLayout() {
  float offsetX = 640/2 - 320;
  drumBaseR[0]=55;
  drumX[0]=150+offsetX;
  drumY[0]=100;
  drumBaseR[1]=45;
  drumX[1]=180+offsetX;
  drumY[1]=230;
  drumBaseR[2]=55;
  drumX[2]=260+offsetX;
  drumY[2]=250;
  drumBaseR[3]=45;
  drumX[3]=330+offsetX;
  drumY[3]=140;
  drumBaseR[4]=45;
  drumX[4]=430+offsetX;
  drumY[4]=140;
  drumBaseR[5]=55;
  drumX[5]=520+offsetX;
  drumY[5]=280;
  drumBaseR[6]=80;
  drumX[6]=380+offsetX;
  drumY[6]=300;
  drumBaseR[7]=65;
  drumX[7]=550+offsetX;
  drumY[7]=120;
  for (int i=0; i<8; i++) drumCurrentR[i]=drumBaseR[i];
}

// ------------------ 드럼 UI 그리기 ------------------
void drawDrumUI() {
  // 배경 흔들림
  bgNoise += 0.01;
  float shake = noise(bgNoise) * bgPulse;
  bgPulse *= 0.9;
  pushMatrix();
  translate(shake, shake);

  for (int i=0; i<8; i++) {
    boolean t1 = dist(lerpX1, lerpY1, drumX[i], drumY[i]) < drumBaseR[i];
    boolean t2 = dist(lerpX2, lerpY2, drumX[i], drumY[i]) < drumBaseR[i];
    boolean isTouching = t1 || t2;
    if (isTouching) {
      drumCurrentR[i] = lerp(drumCurrentR[i], drumBaseR[i] * 1.2, 0.22);
      if (!isDrumHit[i]) {
        drumSounds[i].play();
        isDrumHit[i] = true;
        ripples.add(new DrumRipple(drumX[i], drumY[i], drumBaseR[i], i));
        waveEnergy = 20 + i * 3;
        bgPulse = 3;
      }
    } else {
      drumCurrentR[i] = lerp(drumCurrentR[i], drumBaseR[i], 0.1);
      isDrumHit[i] = false;
    }

    // ---- 드럼 색상 ----
    color mainC, rimC;
    boolean cymbal = (i==0 || i==1 || i==7);

    if (cymbal) {
      mainC = color(240, 200, 40);
      rimC  = color(150, 120, 20);
    } else if (i == 6) {
      mainC = color(70, 40, 20);
      rimC  = color(30, 15, 5);
    } else {
      mainC = color(230);
      rimC  = color(150);
    }

    // 몸체
    noStroke();
    fill(mainC);
    ellipse(drumX[i], drumY[i], drumCurrentR[i]*2, drumCurrentR[i]*2);

    // 림
    noFill();
    stroke(rimC);
    strokeWeight(6);
    ellipse(drumX[i], drumY[i], drumCurrentR[i]*2 + 6, drumCurrentR[i]*2 + 6);

    // 하이라이트
    noStroke();
    fill(255, 60);
    ellipse(drumX[i] - 10, drumY[i] - 10, drumCurrentR[i]*1.2, drumCurrentR[i]*1.2);
  }
  popMatrix();

  // 퍼짐 효과
  for (int j = ripples.size()-1; j >= 0; j--) {
    DrumRipple r = ripples.get(j);
    r.update();
    r.display();
    if (r.isFinished()) ripples.remove(j);
  }
  // 파형
  drawWaveform();
}
// ------------------ 파형 시각화 ------------------
void drawWaveform() {
  waveEnergy *= waveDecay;
  float baseY = 460;
  noFill();
  stroke(255, 200, 0);
  strokeWeight(2);
  beginShape();
  for (int i=0; i<120; i++) {
    float sinWave = sin((frameCount + i * 0.3) * 0.2);
    float noiseWave = noise(i * 0.1, frameCount * 0.02) * 2 - 1;
    float y = baseY + (sinWave + noiseWave) * waveEnergy;
    vertex(20 + i*5, y);
  }
  endShape();
}
// ------------------ 드럼 퍼짐 효과 ------------------
class DrumRipple {
  float x, y, radius, alpha = 150;
  int colIndex;
  DrumRipple(float x, float y, float r, int colIndex) {
    this.x = x;
    this.y = y;
    radius = r;
    this.colIndex = colIndex;
  }
  void update() {
    radius += 4;
    alpha -= 6;
  }
  void display() {
    noFill();
    strokeWeight(3);
    color c;
    switch(colIndex) {
    case 0:
      c=color(255, 200, 0);
      break;
    case 1:
      c=color(200, 200, 0);
      break;
    case 2:
      c=color(180);
      break;
    case 3:
      c=color(150, 0, 0);
      break;
    case 4:
      c=color(180, 0, 0);
      break;
    case 5:
      c=color(200, 0, 0);
      break;
    case 6:
      c=color(100, 50, 0);
      break;
    case 7:
      c=color(255, 150, 0);
      break;
    default:
      c=color(255);
    }
    stroke(c, alpha);
    ellipse(x, y, radius*2, radius*2);
  }
  boolean isFinished() {
    return alpha <= 0;
  }
}
// ------------------ 드럼 사운드 로드 ------------------
void loadDrumSounds() {
  String[] files = {
    "drum/Crash.wav", "drum/HiHat.wav", "drum/Snare.wav",
    "drum/Tom1.wav", "drum/Tom2.wav", "drum/Tom3.wav",
    "drum/Kick.wav", "drum/Ride.wav"
  };
  drumSounds = new SoundFile[8];
  isDrumHit = new boolean[8];
  for (int i=0; i<8; i++) {
    drumSounds[i] = new SoundFile(this, files[i]);
    isDrumHit[i] = false;
  }
}

// ------------------ 웹캠 & 트래킹 ------------------
void drawWebcamAndTrack() {
  pushMatrix();
  translate(camW, 0);
  scale(-1, 1);
  image(video, 0, 0);
  popMatrix();

  float sumX1=0, sumY1=0;
  int count1=0;
  float sumX2=0, sumY2=0;
  int count2=0;

  for (int x=0; x<video.width; x++) {
    for (int y=0; y<video.height; y++) {
      int loc=x+y*video.width;
      color c=video.pixels[loc];
      float d1=dist(red(c), green(c), blue(c), red(trackColor1), green(trackColor1), blue(trackColor1));
      float d2=dist(red(c), green(c), blue(c), red(trackColor2), green(trackColor2), blue(trackColor2));
      if (d1<threshold) {
        sumX1+=x;
        sumY1+=y;
        count1++;
      } else if (d2<threshold) {
        sumX2+=x;
        sumY2+=y;
        count2++;
      }
    }
  }

  if (count1>0) {
    float avgX=sumX1/count1, avgY=sumY1/count1;
    lerpX1=lerp(lerpX1, camW-avgX, 0.1);
    lerpY1=lerp(lerpY1, avgY, 0.1);
  }
  if (count2>0) {
    float avgX=sumX2/count2, avgY=sumY2/count2;
    lerpX2=lerp(lerpX2, camW-avgX, 0.1);
    lerpY2=lerp(lerpY2, avgY, 0.1);
  }
}
