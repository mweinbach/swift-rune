// The system GL 1.1 and WGL exports used directly by Rune. Extensions remain
// context-specific and are resolved through rune_win_gl_proc.
GL_RESULT(HGLRC, wglCreateContext, (HDC dc), (dc), NULL)
GL_RESULT(BOOL, wglDeleteContext, (HGLRC rc), (rc), FALSE)
GL_RESULT(HGLRC, wglGetCurrentContext, (void), (), NULL)
GL_RESULT(HDC, wglGetCurrentDC, (void), (), NULL)
GL_RESULT(PROC, wglGetProcAddress, (LPCSTR name), (name), NULL)
GL_RESULT(BOOL, wglMakeCurrent, (HDC dc, HGLRC rc), (dc, rc), FALSE)
GL_RESULT(GLenum, glGetError, (void), (), GL_INVALID_OPERATION)
GL_RESULT(GLboolean, glIsEnabled, (GLenum cap), (cap), GL_FALSE)
GL_COMMAND(glGetIntegerv, (GLenum name, GLint *value), (name, value))
GL_COMMAND(glBindTexture, (GLenum target, GLuint texture), (target, texture))
GL_COMMAND(glGenTextures, (GLsizei count, GLuint *textures), (count, textures))
GL_COMMAND(glDeleteTextures, (GLsizei count, const GLuint *textures), (count, textures))
GL_COMMAND(glPixelStorei, (GLenum name, GLint value), (name, value))
GL_COMMAND(glTexSubImage2D, (GLenum target, GLint level, GLint x, GLint y, GLsizei width, GLsizei height,
                             GLenum format, GLenum type, const GLvoid *pixels),
                            (target, level, x, y, width, height, format, type, pixels))
GL_COMMAND(glCopyTexSubImage2D, (GLenum target, GLint level, GLint dest_x, GLint dest_y, GLint x, GLint y,
                                 GLsizei width, GLsizei height), (target, level, dest_x, dest_y, x, y, width, height))
GL_COMMAND(glDisable, (GLenum cap), (cap))
GL_COMMAND(glEnable, (GLenum cap), (cap))
GL_COMMAND(glDrawBuffer, (GLenum mode), (mode))
GL_COMMAND(glReadBuffer, (GLenum mode), (mode))
GL_COMMAND(glFinish, (void), ())
