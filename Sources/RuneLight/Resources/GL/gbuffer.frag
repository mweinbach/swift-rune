// Instanced quads arrive in paint order. Two base-1024 digits preserve IDs in RGBA16F.
flat in int primitiveID;
void main() {
    Prim pr = primAt(primitiveID);
    float d = prim_sd(pr, gl_FragCoord.xy);
    if ((flags_of(pr) & F_HINT) != 0u || d > 0.5) discard;
    int id = primitiveID + 1;
    result = vec4(d, float(id % 1024), float(id / 1024), pr.z.y);
}
