#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <SDL2/SDL.h>
static uint32_t start;
static int shot, done, pushed;
static SDL_AudioDeviceID active_capture;
static int allow_capture;
void SDL_GL_SwapWindow(SDL_Window *win) {
  static void (*swap)(SDL_Window*);
  if (!swap) swap=dlsym(RTLD_NEXT,"SDL_GL_SwapWindow");
  uint32_t now=SDL_GetTicks(); if(!start)start=now;
  if(now-start>2000 && shot<7) {
    int w,h; SDL_GL_GetDrawableSize(win,&w,&h);
    void (*readpix)(int,int,int,int,unsigned,unsigned,void*)=SDL_GL_GetProcAddress("glReadPixels");
    void (*pixelstore)(unsigned,int)=SDL_GL_GetProcAddress("glPixelStorei");
    unsigned char *pixels=malloc((size_t)w*h*3); pixelstore(0x0D05,1);
    readpix(0,0,w,h,0x1907,0x1401,pixels);
    char path[512];snprintf(path,sizeof(path),"%s/frame%d.ppm",getenv("WP_CAPTURE"),shot);
    FILE*f=fopen(path,"wb"); if(f){fprintf(f,"P6\n%d %d\n255\n",w,h);for(int y=h-1;y>=0;y--)fwrite(pixels+(size_t)y*w*3,3,w,f);fclose(f);}free(pixels);
    shot++; start=now;
    if(getenv("WP_MIC_SETUP")) {
      SDL_Event e={0};
      if(shot==1 || shot==3){
        allow_capture=1;
        e.type=SDL_MOUSEBUTTONDOWN;e.button.button=SDL_BUTTON_LEFT;e.button.state=SDL_PRESSED;
        e.button.x=185*w/800;e.button.y=530*h/600;SDL_PushEvent(&e);
        e.type=SDL_MOUSEBUTTONUP;e.button.state=SDL_RELEASED;SDL_PushEvent(&e);
      } else if(shot==2 || shot==4){
        e.type=SDL_KEYDOWN;e.key.state=SDL_PRESSED;e.key.keysym.sym=SDLK_ESCAPE;SDL_PushEvent(&e);
        e.type=SDL_KEYUP;e.key.state=SDL_RELEASED;SDL_PushEvent(&e);
      }
    } else if(getenv("WP_OPTIONS") && shot==1){
      int keys[3]={SDLK_DOWN,SDLK_RIGHT,SDLK_RETURN};
      for(int k=0;k<3;k++){SDL_Event e={0};e.type=SDL_KEYDOWN;e.key.state=SDL_PRESSED;e.key.keysym.sym=keys[k];SDL_PushEvent(&e);e.type=SDL_KEYUP;e.key.state=SDL_RELEASED;SDL_PushEvent(&e);}
    } else if(getenv("WP_OPTIONS") && shot==2){
      SDL_Event e={0};e.type=SDL_MOUSEBUTTONDOWN;e.button.button=SDL_BUTTON_LEFT;e.button.state=SDL_PRESSED;e.button.x=462*w/800;e.button.y=305*h/600;SDL_PushEvent(&e);e.type=SDL_MOUSEBUTTONUP;e.button.state=SDL_RELEASED;SDL_PushEvent(&e);
    } else if (getenv("WP_TEST_RAIL") && shot>=2 && shot<=3) {
      int bucket=shot==2?2:26;
      SDL_Event e={0};e.type=SDL_MOUSEBUTTONDOWN;e.button.button=SDL_BUTTON_LEFT;e.button.state=SDL_PRESSED;
      e.button.x=(260+bucket*18+9)*w/800;e.button.y=522*h/600;SDL_PushEvent(&e);
      e.type=SDL_MOUSEBUTTONUP;e.button.state=SDL_RELEASED;SDL_PushEvent(&e);
    } else if (shot==1 || (!getenv("WP_TEST_RAIL")&&shot==2) || (getenv("WP_TEST_RAIL")&&shot==4)) {
      SDL_Event e={0};e.type=SDL_KEYDOWN;e.key.state=SDL_PRESSED;e.key.keysym.sym=SDLK_RETURN;SDL_PushEvent(&e);
      e.type=SDL_KEYUP;e.key.state=SDL_RELEASED;SDL_PushEvent(&e);
    }
    if(getenv("WP_HOTPLUG") && (shot==4 || shot==5)) {
      SDL_Event e={0};e.type=shot==4?SDL_AUDIODEVICEREMOVED:SDL_AUDIODEVICEADDED;
      e.adevice.iscapture=1;e.adevice.which=shot==4?active_capture:0;
      fprintf(stderr,"TEST_HOTPLUG %s id=%u\n",shot==4?"remove":"add",e.adevice.which);
      SDL_PushEvent(&e);
    }
    if(getenv("WP_TEST_TOGGLES") && (shot==4||shot==5)) {
      for(int k=0;k<2;k++){SDL_Event e={0};e.type=SDL_KEYDOWN;e.key.state=SDL_PRESSED;e.key.keysym.sym=k?SDLK_F7:SDLK_F6;SDL_PushEvent(&e);e.type=SDL_KEYUP;e.key.state=SDL_RELEASED;SDL_PushEvent(&e);}
    }
  }
  if(shot==(getenv("WP_QUIT_SHOT")?atoi(getenv("WP_QUIT_SHOT")):7)&&!done){SDL_Event e={0};e.type=SDL_QUIT;SDL_PushEvent(&e);done=1;}
  swap(win);
}
#include <math.h>
static SDL_AudioCallback capture_callback;
static void *capture_userdata;
static int capture_rate, capture_channels;
static double phase, position;
static void synthetic_capture(void *unused, Uint8 *stream, int len) {
  int16_t *s=(int16_t*)stream;
  for(int i=0;i<len/2;i+=capture_channels){
    double hz=261.6256*pow(2.0, (0.35*sin(position*1.7))/12.0);
    double amp=7000+4000*sin(position*.8);
    phase+=2*M_PI*hz/capture_rate;
    for(int c=0;c<capture_channels;c++)s[i+c]=(int16_t)(amp*sin(phase));
    position+=1.0/capture_rate;
  }
  capture_callback(capture_userdata,stream,len);
}
SDL_AudioDeviceID SDL_OpenAudioDevice(const char *device,int iscapture,const SDL_AudioSpec *desired,SDL_AudioSpec *obtained,int allowed){
 static SDL_AudioDeviceID(*openfn)(const char*,int,const SDL_AudioSpec*,SDL_AudioSpec*,int);
 if(!openfn)openfn=dlsym(RTLD_NEXT,"SDL_OpenAudioDevice");
 if(iscapture && getenv("WP_NOMIC_START") && !allow_capture)return 0;
 SDL_AudioSpec spec=*desired;
 if(iscapture&&getenv("WP_SYNTH_PITCH")){capture_callback=spec.callback;capture_userdata=spec.userdata;capture_rate=spec.freq;capture_channels=spec.channels;spec.callback=synthetic_capture;spec.userdata=NULL;}
 SDL_AudioDeviceID id=openfn(device,iscapture,&spec,obtained,allowed);
 if(iscapture && desired->callback && id){active_capture=id;fprintf(stderr,"TEST_CAPTURE_OPEN id=%u\n",id);}
 return id;
}
