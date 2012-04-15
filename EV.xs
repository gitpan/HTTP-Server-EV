#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "EVAPI.h"
#include <sys/types.h>
#include <sys/socket.h>

#define MAX_LISTEN_PORTS 24
#define ALLOCATE 1
#define BUFFERS_SIZE 4100

#define MAX_FILES 50
#define MAX_DATA 2048
#define SOCKREAD_BUFSIZ 4096
#define FILE_BUFSIZ 4096
#define DATA_BUFSIZ 51200
#define MAX_URLENCODED_BODY 102400


#define REQ_METHOD 1
#define URL_STRING 2

#define HEADERS_NOTHING 3

#define HEADER_NAME 4
#define HEADER_VALUE 5

#define BODY_URLENCODED 6

#define BODY_M_NOTHING 7
#define BODY_M_FILE 8
#define BODY_M_DATA 9

#define BODY_M_HEADERS 10
#define BODY_M_HEADERS_NAME 11
#define BODY_M_HEADERS_FILENAME 12

struct port_listener{
	ev_io io;
	SV* callback; 
};

struct req_state {
	ev_io io;
	SV *callback;
	
	int saved_to;
	
	char reading;
	
	int content_length;
	int total_readed;
	
	int post_match_pos;
	int get_match_pos;
	
	int headers_end_match_pos;
	int headers_sep_match_pos;
	
	int multipart_name_match_pos;
	int multipart_filename_match_pos;
	
	int multipart_data_count;
	
	
	char *buf;
	int buf_pos;
	
	char *buf2;
	int buf2_pos;
	
	char *boundary;
	int match_pos;
	
	char *data;
	int data_pos;
	
	char *filepath; 
	
	PerlIO * tmpfile;
	char *tmpbuffer;
	int tmppos;
	int tmpfilesize;
	
	HV* headers;
	
	HV* post;
	HV* post_a;
	
	HV* file;
	HV* file_a;
	
	HV* rethash;
};

///// Wrok with tempfiles

	char tmpdir[BUFFERS_SIZE]={};
	int dirstrlen = 0;
	
	void set_tmpdir (char *new_tmpdir){
		strcpy (tmpdir, new_tmpdir);
		dirstrlen = strlen(new_tmpdir);
	}
	
	
	void create_tmp (struct req_state *state){
		int i;
		//set filename
		for(i = dirstrlen; i < dirstrlen+19 ; i++){ state->filepath[i] = 'a' + rand() % 26; }
		state->filepath[dirstrlen+19]='\0';
		
		if(!( state->tmpfile = (PerlIO *) PerlIO_open(state->filepath, "w")) )
		{ croak("HTTP::Server::EV ERROR: Can`t create tmp file!");};
		
		
		#ifdef USE_ITHREADS
			PerlIO_binmode(NULL, (PerlIO *) state->tmpfile , '>' ,O_BINARY, NULL); 
		#else
			PerlIO_binmode( (PerlIO *) state->tmpfile , '>' ,O_BINARY, NULL); 
		#endif
		
	}
	
	
	SV* tmp_close(struct req_state *state){
			if(!state->tmpfile){
				if(state->tmppos <= 2){ return NULL; }
				create_tmp(state);
			}
			
			HV* hash = newHV();
			hv_store(hash, "size", 4,(SV*) newSViv(state->tmpfilesize-2) , 0);
			state->tmpfilesize = 0;
			hv_store(hash, "path", 4, (SV*) newSVpv( state->filepath , dirstrlen+19 ), 0);
			
			SV* filename =newSVpv(state->buf2, state->buf2_pos);
			SvUTF8_on(filename);
			hv_store(hash, "name" , 4 , filename , 0);
			
			//PerlIO_write(state->tmpfile,state->tmpbuffer, state->tmppos > 2 ? state->tmppos-2 : 0);
			PerlIO_write(state->tmpfile,state->tmpbuffer, state->tmppos-2);
			state->tmppos = 0;
			
			PerlIO_close(state->tmpfile);
			state->tmpfile = 0;
			
		return  sv_bless( newRV_noinc((SV*) hash) ,   gv_stashpv( "HTTP::Server::EV::MultipartFile", GV_ADD) );
	} 
	
	
	int tmp_putc(char chr, struct req_state *state){
	
		state->tmpbuffer[state->tmppos] = chr;
		
		state->tmpfilesize++;
		
		if(state->tmppos >= FILE_BUFSIZ){
			if(!state->tmpfile){ create_tmp(state); printf(""); }
			
			PerlIO_write(state->tmpfile,state->tmpbuffer,FILE_BUFSIZ-1);
			
			state->tmpbuffer[0] = state->tmpbuffer[FILE_BUFSIZ-1];
			state->tmpbuffer[1] = state->tmpbuffer[FILE_BUFSIZ];
			
			state->tmppos = 2;
		} else {
			state->tmppos++; 
		}
	}

	void unlink_all(struct req_state *state){
		if(state->tmpfile){ 
			PerlIO_close(state->tmpfile);
			unlink(state->filepath);
		}
		
		I32 interator = hv_iterinit(state->file_a);
		HE* entry; int i;
		for(i = 0; i < interator ; i++){
			AV* arr = (AV*) SvRV( 
				hv_iterval(  state->file_a, hv_iternext(state->file_a) ) 
			);
			
			I32 len = av_len(arr)+1;
			I32 key;
			//printf("Arr %d\n",len);
			for(key = 0; key < len ; key++){
				HV* hash = (HV*) SvRV( *(av_fetch(arr, key, 0)) );
				
				char *path = SvPV_nolen( *(hv_fetch(hash, "path", 4, 0)) );
				//printf("Path %s\n",path);
				unlink(path);
			}
		}
	}


///// parsers state saving and memory allocating /////
struct req_state* *accepted;
int accepted_pos = 0;

int *accepted_stack;
int accepted_stack_pos = 0;

int accepted_allocated = 0;

struct req_state * alloc_state (){

	// alocate memory if needed
	if( ! accepted_stack_pos ){ 
		int i = accepted_allocated;
		
		accepted_allocated += ALLOCATE;

		if(!( 
				( accepted = (struct req_state **) realloc(accepted,  accepted_allocated * sizeof(struct req_state*) ) ) && 
				( accepted_stack = (int *) realloc(accepted_stack,  accepted_allocated * sizeof(int) ) )
			)
		  ){ croak("CRITICAL ERROR: Can`t allocate memory for saving stream parser state."); }

		
		// push in stack list of free to use elements
		for(; i < accepted_allocated; i++){ 
			accepted[i] = (struct req_state *) malloc( sizeof(struct req_state) );
			
			accepted[i]->buf = (char *) malloc(BUFFERS_SIZE * sizeof(char) );
			accepted[i]->buf2 = (char *) malloc(BUFFERS_SIZE * sizeof(char) );
			accepted[i]->boundary = (char *) malloc(BUFFERS_SIZE * sizeof(char) );
			accepted[i]->data = (char *) malloc(DATA_BUFSIZ * sizeof(char) );;
			
			accepted[i]->tmpbuffer = (char *) malloc(FILE_BUFSIZ * sizeof(char) );
			accepted[i]->filepath = (char*) malloc(BUFFERS_SIZE * sizeof(char));
			strcpy (accepted[i]->filepath, tmpdir);
			
			accepted_stack[accepted_stack_pos] = i;
			accepted_stack_pos++;
		}
	}
	
	//get element from stack
	
	--accepted_stack_pos;
	struct req_state *state = accepted[ accepted_stack[accepted_stack_pos] ];
	
	//set fields to defaults
	memset(state->buf , 0 , BUFFERS_SIZE );
	state->buf_pos = 0 ;
	
	memset(state->buf2 , 0 , BUFFERS_SIZE );
	state->buf2_pos = 0 ;
	
	memset(state->boundary , 0 , BUFFERS_SIZE );
	state->match_pos = 0;
	
	state->reading = REQ_METHOD;
	
	state->content_length = 0;
	state->total_readed = 0;
	
	state->headers_end_match_pos = 0;
	state->headers_sep_match_pos = 0;
	
	state->post_match_pos = 0;
	state->get_match_pos = 0;
	
	
	//state->get = newHV();
	//state->get_a = newHV();
	state->data_pos = 0;
	
	state->tmpfile = 0;
	state->tmppos = 0;
	state->tmpfilesize = 0;
	
	state->multipart_name_match_pos = 0;
	state->multipart_filename_match_pos = 0;
	
	state->multipart_data_count = 0;
	
	state->headers = newHV();
	
	state->post = newHV();
	state->post_a = newHV();
	
	state->file = newHV();
	state->file_a = newHV();
	
	state->rethash = newHV();
	
	hv_store(state->rethash, "post" , 4, newRV_noinc((SV*)state->post), 0);
	hv_store(state->rethash, "post_a" , 6, newRV_noinc((SV*)state->post_a), 0);
	hv_store(state->rethash, "file" , 4, newRV_noinc((SV*)state->file), 0);
	hv_store(state->rethash, "file_a" , 6, newRV_noinc((SV*)state->file_a), 0);
	hv_store(state->rethash, "headers" , 7, newRV_noinc((SV*)state->headers), 0);
	
	state->saved_to = accepted_stack[accepted_stack_pos]; 
	//accepted[ accepted_stack[accepted_stack_pos] ].saved_to = accepted_stack[accepted_stack_pos];
	
	return state; // return pointer to allocated struct
}


void del_state(struct req_state *state){

	SvREFCNT_dec(state->rethash);
	
	accepted_stack[accepted_stack_pos] = state->saved_to;
	accepted_stack_pos++;
}

void push_to_hash(HV* hash, char *key, int  klen, SV* data){
		SV** arrayref;
		if(hv_exists(hash, key, klen )){
			if(arrayref = hv_fetch(hash, key, klen, 0)){
				av_push((AV*) SvRV( *arrayref ) , data);
				SvREFCNT_inc(data);
			}
		} else {
			hv_store(hash, key, klen, newRV_noinc((SV*) av_make(1, &data )  )  , 0);
		}
	}

//////////////////////////////

///// Stream parsing func /////

int search(char input, char *line, int *match_pos ){
	if(input == line[ *match_pos ]){
		(*match_pos)++;
		
		if(! line[ *match_pos ] ){
			*match_pos = 0;
			return 1;
		}
	}else{
		*match_pos = 0;
	};
	return 0;
}


///////////////////////

//// Callbacks ////
void call_perl(struct req_state *state, int socket){
	hv_store(state->rethash, "fd", 2, newSViv(socket), 0);
	dSP;
	ENTER;
	SAVETMPS;
	PUSHMARK(SP);
	EXTEND(SP, 2);
	PUSHs( sv_2mortal( newSViv(state->saved_to) ) );
	PUSHs( sv_2mortal( newRV_inc((SV*)state->rethash) ) );
	PUTBACK;
	
	SV *cb = state->callback;
	del_state( state );
	
	call_sv(cb, G_VOID);
	
	FREETMPS;
	LEAVE;
}
//////////

static void handler_cb (struct ev_loop *loop, ev_io *w, int revents){
	struct req_state *state = (struct req_state *)w;
	char buffer[SOCKREAD_BUFSIZ];
	
	struct sockaddr *buf;
	int bufsize = sizeof(buf);
	
	int readed;
	
	if( ( readed = PerlSock_recvfrom(w->fd, buffer, SOCKREAD_BUFSIZ,  0, buf, &bufsize) ) <= 0 ){
		// connection closed or error
		drop_conn:
		unlink_all(state);
		ev_io_stop(loop, w); 
		del_state(state);
		close( w->fd );
		return;
	}

	int i;
	for(i = 0; i < readed ; i++){
	
		// Read req string
		if(state->reading <= HEADERS_NOTHING) {
			if( search( buffer[i], "\r\n", &state->headers_end_match_pos ) ){
				
				if((state->buf[0] != 'G' && // if not get
					state->buf[0] != 'P' ) //and not post
					|| !state->buf2_pos // or no url
				){ goto drop_conn;} // gtfo faggot
				
				// save to headers hash
				hv_store(state->headers, "REQUEST_METHOD" , 14 , newSVpv(state->buf, state->buf_pos) , 0);
				hv_store(state->headers, "REQUEST_URI" , 11 , newSVpv(state->buf2, state->buf2_pos) , 0);
				
				state->reading = HEADER_NAME;
				state->buf_pos = 0;
				state->buf2_pos = 0;
			}
			
			if(state->reading == URL_STRING){ // reading url string
				if(buffer[i] == ' '){
					state->reading = HEADERS_NOTHING;
				}
				else{
					state->buf2[ state->buf2_pos ] = buffer[i];
					state->buf2_pos++;
					if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
				}
			}
			else if(state->reading == REQ_METHOD) { // reading request method
				if( search(buffer[i], "POST ", &state->post_match_pos ) ){
					strcpy(state->buf, "POST");
					state->reading = URL_STRING;
				}
			
				if( search(buffer[i], "GET ", &state->get_match_pos ) ){
					strcpy(state->buf, "GET");
					state->reading = URL_STRING;
				}
			}
			
		}
		// read headers
		else if(state->reading <= HEADER_VALUE){
			if( search( buffer[i], "\r\n", &state->headers_end_match_pos ) ){
				
				// end of headers
				if(state->buf_pos == 1){
					SV** hashval; 
					char *str;
					
					if(! (hashval = hv_fetch(state->headers, "REQUEST_METHOD" , 14 , 0) ) ){ goto drop_conn;} // goto will never happen...
					str = SvPV_nolen(*hashval);
					
					// method POST
					if( str[0] == 'P'){
						if(! (hashval = hv_fetch(state->headers, "Content-Length" , 14 , 0) ) ){ goto drop_conn;}
						str = SvPV_nolen(*hashval);
						
						state->content_length = atoi(str);
						
						if(! (hashval = hv_fetch(state->headers, "Content-Type" , 12 , 0) ) ){ goto drop_conn;} // goto will never happen...
						int len;
						str = SvPV(*hashval, len);
						
						// multipart post data
						if( str[0] == 'm' && str[1] == 'u' ){ 
							int i; int pos = 2;
							char reading_boundary = 0;
							state->boundary[0] = state->boundary[1] = '-';
							
							for(i = 0; i < len; i++){
								if(reading_boundary){
									state->boundary[pos] = str[i];
									pos++;
								}else
								if(str[i] == '='){ reading_boundary = 1; }
							}
							state->reading = BODY_M_NOTHING;
						}
						// urlencoded data
						else{ 
							if(state->content_length > MAX_URLENCODED_BODY){ goto drop_conn;};
							
							state->reading = BODY_URLENCODED;
							hv_store(state->rethash, "REQUEST_BODY" , 12 , newSVpv("", 0) , 0);
						}
						
						//printf("Boundary: %s \nLen: %d", state->boundary, state->content_length);
						goto end_headers_reading;
					}
					// method GET
					else {
						call_perl(state, w->fd);
						ev_io_stop(loop, w); 
						break;
					}
					
				}
				
				state->reading = HEADER_NAME;
				if(state->buf2_pos > 0){state->buf2_pos -= 1;}  // because we don`t need "\r" in value
				
				//save to headers hash
				hv_store(state->headers, state->buf , state->buf_pos , newSVpv(state->buf2, state->buf2_pos) , 0);
				
				end_headers_reading: 
				state->buf_pos = 0;
				state->buf2_pos = 0;
				
				continue;
			}
			if( search( buffer[i], ": ", &state->headers_sep_match_pos) ){
				state->buf_pos -= 1; // because we don`t need ":" in name
				state->reading = HEADER_VALUE;
				continue;
			}
			
			if(state->reading == HEADER_NAME){ // read header name to buf
				state->buf[ state->buf_pos ] = buffer[i];
				state->buf_pos++;
				if(state->buf_pos >= BUFFERS_SIZE){ goto drop_conn; }
			}
			else{  // read header value to buf2
				state->buf2[ state->buf2_pos ] = buffer[i];
				state->buf2_pos++;
				if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
			}
		}
		// read urlencoded body
		else if(state->reading == BODY_URLENCODED ){
			SV** hashval; 
			if(! (hashval = hv_fetch(state->rethash, "REQUEST_BODY" , 12 , 0) ) ){goto drop_conn;} // goto will never happen...
			int bytes_to_read = readed - i;
			
			if( (state->total_readed + bytes_to_read) > state->content_length ){
				bytes_to_read = state->content_length - state->total_readed;
			}
			
			sv_catpvn(*hashval, &buffer[i] , bytes_to_read );
			state->total_readed += bytes_to_read;
			
			if( state->total_readed >= state->content_length ){ 
				call_perl(state, w->fd);
				ev_io_stop(loop, w); 
				return;
			};
			break;
		}
		//////////////////// Reading multipart //////////////////////////
		else {
			state->total_readed++;
			//reading multipart data or file
			if(state->reading < BODY_M_HEADERS){
			
				if(buffer[i] == state->boundary[state->match_pos]){
					state->match_pos++;
					
					if(! state->boundary[state->match_pos] ){ //matched all boundary
						state->match_pos = 0;
						//printf("\nBoundary matched\n");
								
								if(state->reading == BODY_M_DATA){
									SV* data =  newSVpv(
										state->data_pos-2 ? state->data : "", 
										state->data_pos-2 );
									SvUTF8_on(data);
									
									hv_store(state->post, state->buf , state->buf_pos , data , 0) ;
									push_to_hash(state->post_a , state->buf , state->buf_pos, data);
									
									state->data_pos = 0;
									state->buf_pos = 0;
								}
								else if(state->reading == BODY_M_FILE){
									SV* file = tmp_close(state);
				
									hv_store(state->file, state->buf , state->buf_pos , file , 0);
									push_to_hash(state->file_a, state->buf, state->buf_pos, file );
								
									state->buf_pos = 0;
									state->buf2_pos = 0;
								}
								
								state->reading = BODY_M_HEADERS;
								//headers_first_simb = 1;
					}
				}
				else{
					// reading form input
					if(state->reading == BODY_M_DATA){
						if(state->match_pos){
							int bound_i;
									
							for(bound_i = 0; bound_i < state->match_pos; bound_i++){
								state->data[state->data_pos] = state->boundary[bound_i];
								state->data_pos++;
										
								if(state->data_pos >= DATA_BUFSIZ){ goto drop_conn; }
							}		
						}
								
						state->data[state->data_pos] = buffer[i];
						state->data_pos++;		
						if(state->data_pos >= DATA_BUFSIZ){ goto drop_conn; }
								
					}
					// reading form file
					else if(state->reading == BODY_M_FILE){
						if(state->match_pos){
							int bound_i;
							for(bound_i = 0; bound_i < state->match_pos; bound_i++){
								tmp_putc(state->boundary[bound_i], state);
							}
						}
						tmp_putc(buffer[i], state);
					};
							
					state->match_pos = 0;
				}
			}
			// Reading multipart headers
			else if(state->reading >= BODY_M_HEADERS){
					//buf - name
					//buf2 - filename
					
				// searching for name
				if(search(buffer[i], " name=\"", &state->multipart_name_match_pos) && !(state->buf_pos)){
					state->reading = BODY_M_HEADERS_NAME;
					//printf("Name match\n");
					continue;
				}
				// reading name
				else if(state->reading == BODY_M_HEADERS_NAME){
					if(buffer[i] == '"'){
						state->reading = BODY_M_HEADERS;
						continue;
					}else{
						state->buf[ state->buf_pos ] = buffer[i];
						state->buf_pos++;
						if(state->buf_pos >= BUFFERS_SIZE){ goto drop_conn; }
					}
				}
				
				// searching for filename
				else if(!(state->buf2_pos) && search(buffer[i], "filename=\"", &state->multipart_filename_match_pos)){
					state->reading = BODY_M_HEADERS_FILENAME;
					//printf("FileName match\n");
					continue;
				}
				// reading filename
				else if(state->reading == BODY_M_HEADERS_FILENAME){
					if(buffer[i] == '"'){
						state->reading = BODY_M_HEADERS;
						continue;
					}else{
						state->buf2[ state->buf2_pos ] = buffer[i];
						state->buf2_pos++;
						if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
					}
				};
				
						
				// searching for end of headers
				if(search( buffer[i], "\r\n\r\n", &state->headers_end_match_pos) ){

					if( 
						state->reading == BODY_M_HEADERS_NAME ||
						state->reading == BODY_M_HEADERS_FILENAME //||
					//	!state->buf_pos // Did some browsers may send form fields with empty name?
					){ goto drop_conn; } //malformed multipart headers
						
					//printf("\nEnd of fileheader matched\n");	
					
					//filename defined or not
					state->reading = state->buf2_pos ? BODY_M_FILE : BODY_M_DATA;
					
					if(state->multipart_data_count > MAX_DATA){ goto drop_conn; }
					state->multipart_data_count++;
						
					continue;
				}
			}
			
			//end of stream
			if( state->total_readed >= state->content_length ){ 
				if( state->reading == BODY_M_HEADERS || state->reading == BODY_M_NOTHING ){
					call_perl(state, w->fd);
					ev_io_stop(loop, w); 
					return;
				}
				goto drop_conn;
			};
		}
	}
}

static void listen_cb (struct ev_loop *loop, ev_io *w, int revents){	
		struct port_listener *listener = (struct port_listener *)w;
		
		int accepted_socket;
		struct sockaddr_in cliaddr;
		int addrlen = sizeof(cliaddr);
		
		if( ( accepted_socket = accept( w->fd , (struct sockaddr *) &cliaddr, &addrlen ) ) == -1 )
		{ croak("HTTP::Server::EV ERROR: Can`t accept connection. Enlarge your number of open file descriptors"); }; //ERROR: Enlarge your penis
		
		struct req_state *connect_handler = alloc_state();
		connect_handler->callback = listener->callback;
		
		hv_store(connect_handler->headers, "REMOTE_ADDR" , 11 , newSVpv(inet_ntoa( cliaddr.sin_addr ), 0 ) , 0);
		
		//handler_cb(loop, &connect_handler->io, revents);
		
		ev_io_init (&connect_handler->io, handler_cb, accepted_socket , EV_READ);
		ev_io_start ( loop, &connect_handler->io);
		
}


struct port_listener listeners[MAX_LISTEN_PORTS];
int listeners_pos = 0;



void listen_socket(PerlIO* sock, SV* callback){
			
		SvREFCNT_inc(callback);
		listeners[listeners_pos].callback = callback;
		
		ev_io_init (&listeners[listeners_pos].io, listen_cb, PerlIO_fileno((PerlIO*)*sock), EV_READ);
		ev_io_start (EV_DEFAULT, &listeners[listeners_pos].io);
		
		listeners_pos++;
		
}

MODULE = HTTP::Server::EV	PACKAGE = HTTP::Server::EV	

PROTOTYPES: DISABLE

BOOT:
{
			I_EV_API ("HTTP::Server::EV");
}


void
listen_socket ( sock , callback)
	PerlIO* sock
	SV* callback
	PREINIT:
	I32* temp;
	PPCODE:
	temp = PL_markstack_ptr++;
	listen_socket(sock,callback);
	if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
	  PL_markstack_ptr = temp;
	  XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
	return; /* assume stack size is correct */
	
	
void
close_socket ( fdesc )
	int fdesc
	PREINIT:
	I32* temp;
	PPCODE:
	temp = PL_markstack_ptr++;
	close( fdesc );
	if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
	  PL_markstack_ptr = temp;
	  XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
	return; /* assume stack size is correct */
	
	
	
void
set_tmpdir ( new_tmp )
	char *new_tmp
	PREINIT:
	I32* temp;
	PPCODE:
	temp = PL_markstack_ptr++;
	set_tmpdir(new_tmp);
	if (PL_markstack_ptr != temp) {
          /* truly void, because dXSARGS not invoked */
	  PL_markstack_ptr = temp;
	  XSRETURN_EMPTY; /* return empty stack */
        }
        /* must have used dXSARGS; list context implied */
	return; /* assume stack size is correct */

	
	
SV * get_request( stack_pos )
	int stack_pos
    CODE:
        RETVAL =  newRV_inc((SV*)accepted[ stack_pos ]->rethash);
		del_state( accepted[ stack_pos ] );
    OUTPUT:
        RETVAL
		
		